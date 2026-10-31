# The wake queue and the task inboxes on the bus, in shadow

Migration step 5b. The wake queue and the per-task steering inboxes are files with
locks, drains, atomic rewrites and doorbells. The decided shape is NATS JetStream:
its sequence replaces the sequence file, its message-id dedupe replaces the
re-enqueue dedupe, and its history keeps an event after its consumer is done with
it. This step proves the bus reproduces the file path's consumer result before
anything switches.

Nothing switches here. Both paths run at once, the files stay authoritative, and
`bin/jg-wake-bus.sh` writes nothing into the file path.

## What runs

- `bin/jg-wake-bus.sh sync` scans one home's file path and mirrors every record it
  holds to two JetStream streams, `JG_WAKE` (`jg.wake.>`) and `JG_INBOX`
  (`jg.inbox.>`), file storage with `JG_BUS_MAX_AGE` of history (168h by default,
  because the replay window needs history).
- A home turns the mirror on with `config/wake-bus`, the same way `config/fleet-ledger`
  turns the ledger on. `bin/jg-watch.sh` then runs one `sync` per poll, so both paths
  really do run at once. Off costs one file test.
- The mirror never becomes a dependency: a missing client, a missing server, or any
  transport failure prints `skip: ...` or is swallowed, and the file path behaves
  exactly as before. `view` and `parity` are explicit commands and are not gated.
- `$STATE/wake-bus.jsonl` is the shadow record: each event is appended once it is
  published, and it is the mirror's cache of what went out, which is what keeps a
  sync cheap instead of reading the whole stream. The file path is the event's
  durable record, so a publish that fails records nothing and the next sync tries
  again; `Nats-Msg-Id` makes any repeat a no-op on the server.

## The event model

One event per durable record, and the same id settles the record later:

| record | event | settled by |
| --- | --- | --- |
| a queued wake row | `jg.wake.raise`, `where=queue`, with kind, key, payload and the class it was raised with | `jg.wake.ack` with the same id |
| a record-only (`silent`) wake | `jg.wake.settled`, `where=settled` | never: it is a record, not a queue entry |
| an unhandled inbox record | `jg.inbox.raise`, with task, sequence, delivery class, body and its sha256 | `jg.inbox.ack` with the same id |
| a handled inbox record | the raise and its acknowledgement | - |

The fold is last-raise-wins per id, so a corrected or replayed event never counts
twice, and an acknowledgement settles its raise. A queue row that disappears from
the file path - consumed by a drain, moved into `handled/` by a worker, or
withdrawn by its producer - is the same thing to a consumer: no longer queued. The
shipped path publishes one acknowledgement for all three.

## The parity contract

`bin/jg-wake-bus.sh parity [--since-hours N]` replays the window through both paths
and compares the consumer result row by row. Both sides produce the same rows:

```
wake  <id> queue   <kind> <key> <payload> <class>
wake  <id> settled <kind> <key> <payload> silent
inbox <id> pending <delivery> <body-sha256>
inbox <id> handled <delivery> <body-sha256>
```

So "the same wake raised", "the same task", "the same class" and "the same
acknowledgement" are all one `diff` over that list, and a difference names the
record and the field that differs. The class on the file side is computed now by
the routing owner (`jg_wake_route_class`), not copied from the event, so a routing
change since the event was raised shows up as a difference instead of hiding.

The file path is live while the comparison runs, so the check scans the file path
twice, syncs between the scans, and compares only the rows both scans agree on.
Rows that arrived or were consumed mid-run are reported as `churned` rather than
counted as a difference they are not.

`--corrupt` republishes one existing event with tampered fields under a different
message id. The fold's last-raise-wins then presents the tampered row, so a
corrupted event must produce a difference. A run that stayed green after that would
mean the check is vacuous.

### What it does not prove

The mirror is fed by the file path, so this proves the transport and consumer half:
ordering, dedupe, acknowledgement, retention and the fold. It does not prove a
producer that publishes at the source; that hook, and the reader that stops
consulting the files, are what the switch itself adds. One asymmetry is inherent to
this step and matters for the switch: the drain deletes a consumed wake row, so the
file path keeps no record of the acknowledgement at all and only the bus can count
wake acknowledgements. Inbox acknowledgements do have a file-side record - the move
into `handled/` - and are compared like any other row.

The re-alert gate is also outside this comparison: the shipped path downgrades a
repeated urgent event to `batch` through `$STATE/.wake-realert`, and both sides here
read the class from the routing rules instead. A switch replaces that gate with the
bus's own dedupe window, so it is named here rather than modelled twice.

## Measured

Measured on the branch that added this, with `wc -l` and the function spans named
here; nothing below is an estimate.

Bus path, `bin/jg-wake-bus.sh`: 571 lines.

- 78 header and argument handling.
- 286 for the mirror, in 21 functions: the file scan, the row-to-event and
  row-to-acknowledgement builders, the record, and `mirror_home`.
- 207 for the replay, in 9 functions: `bus_dump`, `bus_fold`, `bus_rows`,
  `scan_window`, `cmd_parity`, `corrupt_one_event`.

File path, the plumbing the queue and the inboxes cost today:

- 1,322 lines of `bin/jg-wake-lib.sh` in the queue, lock and recovery functions
  that exist for the queue: the append lock, the sequence file, the atomic
  whole-file rewrite, `withdraw`, and the watcher-down recovery protocol that
  notices a queue whose consumer died. The generic `jg_lock_*` primitives are
  shared with other paths, so not all of that 1,322 disappears with the queue.
- 534 lines of `bin/jg-task-inbox-lib.sh` below its 104-line header: sequence
  allocation under `.seq.lock`, the want/have re-enqueue dedupe, the record format,
  the handled move and the re-ring ladder's durable budgets.
- 337 lines of `bin/jg-wake-drain.sh` in the five functions that read, rewrite and
  consume the queue file. The presentation half of that script stays.

That is 2,193 file-path lines against 571 bus-path lines: a switch would remove
about 1,600 lines net, and it would remove these mechanisms with them:

- the queue lock file and its stale-owner steal machinery, because the server
  serialises publishes and the message id dedupes a repeat;
- the sequence file and the atomic rewrite of the whole queue on every
  acknowledgement;
- `.wake-settled`, because a stream keeps a record-only event as history;
- the re-enqueue dedupe in the inbox writer;
- the watcher-down recovery marker for the queue, because an unacknowledged message
  stays on the server and the consumer's own position is durable;
- and it would add the one thing the files cannot do: 24 hours of wake history. The
  file path deletes a wake when it is handled, which is why this step's replay of
  the last 24 hours compares inbox records and the rows still queued, and only the
  bus can report a consumed wake's acknowledgement.

## Replaying a real fleet

```sh
# mirror every home that had traffic, without writing into those homes
for h in "$@"; do args+=(--home "$h"); done
JG_WAKE_BUS_SHADOW=on bin/jg-wake-bus.sh "${args[@]}" --record-dir /tmp/wake-bus sync
bin/jg-wake-bus.sh "${args[@]}" --record-dir /tmp/wake-bus --since-hours 24 parity
```

`--record-dir` keeps the shadow record outside the mirrored home, so a fleet-wide
replay never writes into a home it is only reading. `JG_WAKE_BUS_SHADOW=on` enables
the mirror for the run without a `config/wake-bus` file in every home.

## Test

`tests/jg-wake-bus-parity.test.sh` starts a throwaway server on a free port, writes
the file side with the production writers, and proves the check in both directions:
parity is green with a count and zero differences, and one corrupted event on the
bus path fails the same check. The test gate-skips when `nats-server` or the `nats`
client is missing; set `JG_NATS_SERVER` and `JG_NATS_BIN` to pin them.
