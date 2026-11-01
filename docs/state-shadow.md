# The task leases, live, and the busy events, in shadow

Migration step 5e, in two halves.
A task lease says which supervision actor is changing a task right now, and a busy event says what the harness last reported about a worker.
Both are small records with expiry semantics, and each used to cost a directory lock, a gen validation, an atomic replace, and a sweep that cleared what a dead session left behind.
The decided shape is a NATS JetStream key-value bucket: one key per record, its revision in place of the writer lock, its own delete in place of the stale sweep, and a watch in place of the poll.

The leases have SWITCHED: the bucket is now the only record, and the file path that mirrored it is deleted.
The busy events are still mirrored in shadow, with the files authoritative, until their own switch proves the same parity.
The lease contract itself - record format, actors, staleness, guard semantics - is owned by `bin/jg-lease-lib.sh`; the client surface is owned by `bin/jg-kv-lib.sh`.

## The lease path, live

- A lease is one key, `lease/<home>/<task>`, in the bucket `JG_LEASES`, and its value is the same `<actor>\t<pid>\t<epoch>` line the file path held.
  `<home>` is the home directory's name plus the first eight hex digits of its path hash, so two homes that both run a task named `lane-a` never share a key.
- The bucket's revision is the writer lock.
  A first claim is a `create`, which the server refuses when the key already exists; a refresh of the holder's own lease, or a takeover of a stale one, is an `update` pinned to the revision just read.
  A writer that loses that race re-reads the record, finds the winner's live lease, and refuses.
- Expiry is unchanged: a lease is live while its recorded pid is alive and is the current session-lock holder.
  There is no bucket TTL, because a TTL would age out a holder that still holds the task.
- The store is required exactly where a lease decision is needed.
  A home in no supervision context, holding no lease, that runs no supervision host never asks the bucket anything and needs no bus.
  A home that does need to decide refuses rather than guessing: a guard that cannot read the record has not decided anything, so a steer, teardown, or lifecycle action stops with exit 1 and names the missing store, and `bin/jg-lease.sh check` exits 2 instead of reporting an empty task.
- The guard is a read, and it leaves no record behind, so an abandoned guarded action leaves nothing to expire.
  The home-local lock the file path held across a guarded mutation is gone; what serializes a takeover is the claim's compare-and-set.
  One residual replaces the old one and is accepted at the same CONFUSED-AGENT-GRADE severity the lease header documents: between a guard's read and the caller's mutation, the other actor could claim the task, which the lock used to exclude.
- A home that upgrades keeps the `.lease-*` files the old path left, and nothing reads or writes them any more; they are inert and safe to delete by hand.

### The one-step reversal

`git revert <the switch commit>` on `release/c-1` restores the file path exactly: this change adds no data format the old code cannot ignore and deletes no record.
What a revert does not restore is the state of a lease that was live in the bucket at that instant: the file path starts empty, so for the length of that revert the other actor is not excluded by a lease the old code cannot see.
Nothing else needs undoing, because nothing else switched.

## What the switch removed

Measured with `git diff --numstat` at the switch's head; nothing below is an estimate.
The code and test lines are counted here, and the change's own PR body carries the whole-change count.

| Where | Removed | Added | Net |
| --- | --- | --- | --- |
| `bin/jg-lease-lib.sh` | 217 | 217 | 0 |
| `bin/jg-lease.sh` | 84 | 34 | -50 |
| `bin/jg-state-bus.sh` | 312 | 87 | -225 |
| `bin/jg-kv-lib.sh` (new) | 0 | 160 | +160 |
| other `bin/` files | 3 | 4 | +1 |
| **`bin/` total** | **616** | **502** | **-114** |
| `tests/` | 344 | 308 | -36 |

The groups that went with them: the lease-command lock and everything it needed - the bounded acquire, the stale-owner reclaim, the steal-mutex election, the scratch sweep, the owner-task record, the four bound readers, and the lazy lock-helper source; the guard's retained lock and its release body; `bin/jg-lease.sh`'s command lock and trap, its temp-file `ln`/`mv` claim, its file sweep and its lock-scratch report; and the lease half of the shadow, which is the lease snapshot, the lease rows, the replayed claims, the bucket-side claim, the lease restore, and the lease tamper.

Two record readers stay either way and are deliberately not counted as removed: the lease reader with its liveness rule, which the guard and every caller still use, and the busy record's parse and gen check, which both paths of the busy half read a record with.

Three things a deletion had to leave alone, and why:

- `jg_lease_guard_release`, kept as a no-op because `bin/jg-send.sh`, `bin/jg-control.sh`, and `bin/jg-teardown.sh` still call it from their EXIT cleanup, and `bin/jg-teardown.sh` belongs to another switch in flight.
  The last call site removes it.
- `bin/jg-wake-lib.sh`'s lock-scratch sweep, which the deleted lease lock was the last caller of, because that library is being restructured by the same parallel switch.
- The busy half of the shadow, which is not this path.

## The parity replay that gated the switch

`bin/jg-state-bus.sh parity` replayed recorded traffic over two real homes through both paths at the instant before the switch.
Recorded evidence: 49 rows over 2 replayed instants - 46 busy rows, 1 lease row, and 2 replayed claim decisions on that lease (the holder's refresh granted, the other actor's claim refused `held-by-other`) - with **zero differences**.
The same run with `--corrupt` reported 6 differences naming the lease and the flipped verdicts, so a green run is not vacuous.
That artifact is private task evidence (`data/switch-leases-live/replay-recorded-traffic.txt`), not tracked here, because it names one captain's homes and their tasks.

## The busy half, still in shadow

- `bin/jg-state-bus.sh sync` takes one snapshot of a home's busy records and mirrors every record it holds into the bucket `JG_BUSY`, file storage with eight revisions kept per key so a watcher can see a record's last transitions.
- A home turns the mirror on with `config/state-bus`, which may also set `nats-url <url>`; `bin/jg-watch.sh` then runs one `sync` per poll, so both paths really do run at once.
  Off costs one file test.
- The mirror never becomes a dependency: a missing client, a missing server, or any transport failure prints `skip: ...` and the file path behaves exactly as before.
  `parity` is the opposite, because it is an explicit check: a bus it cannot reach fails it rather than skipping it.
- There is no shadow record file: the file path is the record, so a sync compares the bucket against the snapshot and republishes only what changed.

### The busy key layout

| record | key | value |
| --- | --- | --- |
| a busy event | `busy/<home>/<task>` | the gen sidecar's line, then the record's line |

The value is the file path's own bytes and never a re-encoding, so "the same record" is a byte comparison and both sides are read by the same functions.

### The busy parity contract

`bin/jg-state-bus.sh parity` snapshots each home once and then replays that one instant through both paths, so a retire that lands mid-run cannot be reported as a difference.
Both sides produce the same canonical rows:

```
busy <home> <task> <gen> <state> <source> <event> <seq>
busy <home> <task> <gen> <reason>
```

So "the same record, gen, and sequence" is one `diff` over that list, and a difference names the record and the field that moved.
A run that compared nothing is not a pass, so `parity` reports its count and fails when the count is zero.
`--corrupt` rewrites one published record's state first, and the next `sync` mirrors the truth back over it.

### What the busy half does not prove

- The busy record's own refusal. A busy event applied with a stale gen is refused by `bin/jg-busy-event.sh`, and that path is not replayed: the replay compares the record each path presents, not the write that would advance it.
- `state/<id>.progress`, which is a touched marker rather than an event. A switch folds it into the same key; here it is not mirrored and not compared.
- Coordination across homes. A busy record is home-local by contract, and so is this mirror: two homes that run the same task get two keys, never one.

## Replaying a real fleet

```sh
JG_STATE_BUS_SHADOW=on bin/jg-state-bus.sh --home ~/firstmate sync
bin/jg-state-bus.sh --home ~/firstmate parity
bin/jg-state-bus.sh --home ~/firstmate parity --corrupt
```

`JG_STATE_BUS_SHADOW=on` enables the mirror for a run without a `config/state-bus` file, and the parity commands write nothing into the home they read: the snapshot copies live under the temporary directory.

## Tests

`tests/jg-lease-live.test.sh` proves the live path through the shipped commands against a throwaway JetStream server: a claim is live, the other actor's claim is refused with exit 6, a refresh is granted, a stale record is taken over, a release and `release-actor` drop exactly what they name, `sweep` removes only the stale records, a watcher sees the claim and the release, the guard refuses a steer through `bin/jg-send.sh`, and an unreachable store refuses instead of reading as an empty lease.

`tests/jg-state-bus-parity.test.sh` starts a throwaway server, writes the file side with the production busy writer, and proves the busy parity in both directions: green with a count and zero differences, one tampered value failing it, the next mirror healing it, and a retire arriving as the delete a watcher observes.

Both tests gate-skip when `nats-server` or the `nats` client is missing; set `JG_NATS_SERVER` and `JG_NATS_BIN` to pin them.
