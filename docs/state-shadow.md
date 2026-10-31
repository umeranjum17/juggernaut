# The task leases and busy events on the key-value bus, in shadow

Migration step 5e.
A task lease (`state/.lease-<task>`) says which supervision actor is changing a
task right now, and a busy event (`state/<id>.busy-state` plus its
`<id>.busy-gen` sidecar) says what the harness last reported about a worker.
Both are small records with expiry semantics, and each costs a directory lock, a
gen validation, an atomic replace and a sweep that clears the stale copies.
The decided shape is a NATS JetStream key-value bucket: one key per record, its
revision in place of the writer lock, its own delete in place of the stale sweep,
and a watch in place of the poll.
This step proves the bucket reproduces what the file path reports before anything
switches.

Nothing switches here.
Both paths run at once, the files stay authoritative, and `bin/jg-state-bus.sh`
writes nothing into the file path.

## What runs

- `bin/jg-state-bus.sh sync` takes one snapshot of a home's file path and mirrors
  every record it holds into two buckets, `JG_LEASES` and `JG_BUSY`, both file
  storage with eight revisions kept per key so a watcher can see a record's last
  transitions.
- A home turns the mirror on with `config/state-bus`, the same way
  `config/wake-bus` turns the wake mirror on, and `bin/jg-watch.sh` then runs one
  `sync` per poll, so both paths really do run at once.
  Off costs one file test.
- The mirror never becomes a dependency: a missing client, a missing server or any
  transport failure prints `skip: ...` and the file path behaves exactly as
  before.
  `parity` is the opposite, because it is an explicit check: a bus it cannot reach
  fails it rather than skipping it, so a run that did not happen is never readable
  as a green one.
- There is no shadow record file: the file path is the record, so a sync compares
  the bucket against the snapshot and republishes only what changed.
  A value that already matches is not written again, so a poll cannot flood a
  watcher with unchanged records.

## The key layout

| record | key | value |
| --- | --- | --- |
| a task lease | `lease/<home>/<task>` | the lease line unchanged: actor, pid, epoch |
| a busy event | `busy/<home>/<task>` | the gen sidecar's line, then the record's line |

`<home>` is the home directory's name plus the first eight hex digits of its path
hash, because two homes can both run a task named `lane-a` and a KV key admits no
colon.
The values are the file path's own bytes and never a re-encoding, so "the same
owner identity at the same instant" is a byte comparison and both sides are read
by the same functions rather than by a second copy of the rules.

## The expiry rule

The file path's expiry is not a clock.
A lease expires when its recorded pid is dead or is no longer the session-lock
holder, and a busy record expires when its gen no longer matches the armed gen.
The mirror therefore expires nothing on its own: it carries the record and deletes
the key when the file path deletes the record, so a release and an expiry arrive
as the delete a watcher observes.
A bucket TTL would be a different behaviour, because a live holder would age out
while it still held the task.
Reaching that behaviour needs a lease refresh the file path does not have, so it
belongs to the switch and is named under what this step does not prove.

## The parity contract

`bin/jg-state-bus.sh parity` snapshots each home once and then replays that one
instant through both paths.
One instant is why there is no churn accounting: a release or an expiry that lands
while the check runs cannot reach either side of the comparison.
Both sides produce the same canonical rows:

```
lease <home> <task> <actor> <pid> <live|stale>
busy  <home> <task> <gen> <state> <source> <event> <seq>
busy  <home> <task> <gen> <reason>
claim <home> <task> <claimant> granted <actor>
claim <home> <task> <claimant> refused <reason>
```

So "the same holder for the same task at the same instant" is one `diff` over that
list, and a difference names the record and the field that moved.
A run that compared nothing is not a pass: an empty fleet must never be able to
read a green parity as this switch's evidence, so `parity` reports its count and
fails when the count is zero.

The `claim` rows are the replay.
For every recorded lease, both supervision actors claim it in turn: the holder's
own claim is a refresh and must be granted, and the other actor's claim must be
refused while the record is live and granted once it has expired.
The file side runs the shipped `bin/jg-lease.sh` against a copy of the state
directory, so its refusal is the shipped one and its reason is that command's own
exit code; the bus side is the bucket's claim, judged by the same expiry rule.
The liveness context is the record's pid when that pid is alive and a definitely
dead pid otherwise, because a recorded pid is a fact about the recording session
rather than about the claim.

`--corrupt` tampers with one published value first: a lease's actor is flipped,
which moves its own row and the verdict of every claim replayed against it, and a
busy record's state is rewritten when there is no lease to flip.
The next `sync` mirrors the true value back over it, so a replay never leaves the
shadow holding a lie.

### What it does not prove

- The bucket TTL, and with it a lease that ages out while its holder still lives.
  That needs a refresh cadence the file path does not have, so the expiry here is
  the file path's own liveness verdict and nothing more.
- The busy record's own refusal. A busy event applied with a stale gen is refused
  by `bin/jg-busy-event.sh`, and that path is not replayed: the replay compares the
  record each path presents, not the write that would advance it.
- `state/<id>.progress`, which is a touched marker rather than an event. A switch
  folds it into the same key; here it is not mirrored and not compared.
- A torn or foreign record. The `.lease-*` surface also holds other homes' index
  files, and the lease reader's own validation is what keeps them out of both
  paths rather than a name pattern.
- Coordination across homes. A lease is home-local by contract, and so is this
  mirror: two homes that run the same task get two keys, never one.

## Measured

Measured on the branch that added this, with `wc -l` and the function spans named
here; nothing below is an estimate.

Bus path, `bin/jg-state-bus.sh`: 500 lines.

- 60 header and contract, including `set -u`.
- 92 shared vocabulary: the client gate, the buckets, the key reads and writes,
  the home key and the dead-pid helper.
- 75 for the file path's instant: `snapshot_home` and `rows_of`.
- 64 for the replayed claims: `claim_rows` and `kv_claim`.
- 102 for the mirror: `restore_bus`, `sync_snapshot` and `corrupt_one`.
- 68 for the two subcommands, and 39 for argument handling.

Of those 500 lines, 119 exist only for the replay, in four functions:
`claim_rows`, `kv_claim`, `corrupt_one` and `cmd_parity`.

File path, the plumbing these two records cost today:

- 118 lines of `bin/jg-lease-lib.sh`: the lease-command lock with its stale-owner
  reclaim and its bounded wait (80), and `jg_lease_guard` with its release (38).
- 160 lines of `bin/jg-lease.sh` below its 60-line header: claim, release, check,
  the sweep, and the argument handling all five share.
- 209 lines of `bin/jg-busy-event.sh` below its 62-line header: the incarnation
  lock, the atomic record replace, and arm, apply, progress and retire.
- 7 lines of `bin/jg-lease-lib.sh` for `jg_lease_clear_stale`.

That is 494 file-path lines against 381 bus-path lines that a switch would carry,
so the line win is about 110 and small.
The mechanisms are the point: the lease-command lock, its steal mutex and its
stale-owner reclaim; the atomic replace of the whole record on every write; the
gen sidecar pair; and the sweep that clears what a dead session left.
A watcher replaces the poll, and the server's revision replaces the lock.

Two record readers stay either way, and are deliberately not counted as removed:
`jg_lease_read` with `jg_lease_live` (31 lines) is the expiry rule this shadow
reuses, and the busy record's parse and gen check (67 lines of
`bin/jg-busy-lib.sh`) is what both paths read a record with.

## Replaying a real fleet

```sh
JG_STATE_BUS_SHADOW=on bin/jg-state-bus.sh --home ~/firstmate sync
bin/jg-state-bus.sh --home ~/firstmate parity
bin/jg-state-bus.sh --home ~/firstmate parity --corrupt
```

`JG_STATE_BUS_SHADOW=on` enables the mirror for a run without a `config/state-bus`
file, and the parity commands write nothing into the home they read: the snapshot
and the replay copies live under the temporary directory.

The two real homes on this machine, replayed together: 28 records mirrored (1
lease, 27 busy records), 52 events compared including the replayed claims on that
one lease, and zero differences.
The same run with `--corrupt` reported six difference lines and named the task.

## Test

`tests/jg-state-bus-parity.test.sh` starts a throwaway server on a free port,
writes the file side with the production writers, and proves the check in both
directions: parity is green with a count and zero differences, one tampered lease
value fails it, one tampered busy value fails it and the next mirror heals it, a
release reaches the bus as the delete a watcher observes, and a watcher sees the
claim and the release itself.
The test gate-skips when `nats-server` or the `nats` client is missing; set
`JG_NATS_SERVER` and `JG_NATS_BIN` to pin them.
