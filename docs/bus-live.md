# The wake queue and the task inboxes, live on the bus

The wake queue and the per-task steering inboxes were files with a lock, a
sequence file, an atomic rewrite of the whole file on every acknowledgement, a
record-only file and a recovery marker for a queue whose consumer had died. This
is the switch: the bus is the store, and one renderer writes the read model every
other reader still opens.

`docs/bus-shadow.md` is the step before this one - the mirror and the parity
replay that proved the bus reproduces the file path's consumer result. That
replay still runs and is still the evidence this switch rests on.

## What is authoritative now

| record | the bus holds it as | settled by |
| --- | --- | --- |
| a queued wake | `jg.wake.raise` with kind, key, payload and class | `jg.wake.ack` with the same id |
| a record-only (`silent`) wake | `jg.wake.settled` | never: it is a record |
| an inbox record | `jg.inbox.raise` with task, sequence, delivery class and body sha256 | `jg.inbox.ack` with the same id |

Two things follow, and both are the point of the switch:

- **The server assigns the row's sequence.** It is the message's stream sequence,
  so a row's number survives a crash, a restart and two producers at once, which
  is what the sequence file and its lock were for.
- **An unacknowledged event stays on the server.** Nothing has to notice that a
  consumer died, so the queue's own append-recovery marker and the `.wake-settled`
  file are gone with the mechanisms they served.

## The read model

`state/.wake-queue` and `state/.wake-settled` still exist, in exactly the format
they always had. Nothing appends to them any more: `bin/jg-wake-bus.sh render`
folds the bus into them, atomically, and every reader that used to `awk` the
queue - the drain, the guard, the session digest, the mail check, the lead and
host-memory wakers - keeps working unchanged.

Three files hold the live path's own state, and all three are caches of the bus:

- `state/.wake-bus.events.jsonl` - this home's unsettled events, each with its
  stream sequence. An acknowledgement drops its raise with it, so the fold stays
  small.
- `state/.wake-bus.cursor` - the last sequence already applied, per stream, which
  is what makes a render cost nothing when nothing new arrived.
- `state/.wake-bus.outbox.jsonl` - events a failed publish still owes the bus. A
  home whose bus is briefly unreachable loses no wake: the event waits here and
  the next render publishes it.

Losing all three is safe: the next render rebuilds them from the stream.

## Producers and consumers

- `jg_wake_append` publishes a raise and renders. It takes no lock, because the
  server serialises its own appends and the sequence file is gone.
- `jg_wake_withdraw` reads the matching ids from the replica and acknowledges
  them, which replaces the whole-file rewrite it used to do.
- The drain acknowledges row by row: `bin/jg-wake-bus.sh ids-through <cutoff>
  [<actor-rows-file>]` names exactly the ids this actor may consume and publishes
  one acknowledgement per row. The read model is rendered before the drain reads
  it and again by the acknowledgement.
- A task inbox publishes at the writer, in `jg_task_inbox_write`, so no scan has
  to find a new steer. A worker still acknowledges a steer by moving its record
  into `handled/`, so the watcher's poll carries that move to the bus with
  `bin/jg-wake-bus.sh inbox-settle`: a record missing from its inbox is
  acknowledged, a record still there is left alone.

## The one-step reversal

`echo off > config/wake-bus` returns that home to the file behaviour on the spot:
rows are held in the home's own outbox, nothing is published, and the read models
are written from those rows exactly as before. Delete the file to go live again.
No code is reverted, and the events an off home accumulated reach the bus on the
first render after the file is gone.

## What was deleted with the old path

- the append lock around an append (`JG_WAKE_QUEUE_LOCK` is still the drain's and
  the grant's lock) and `.wake-queue.seq` with its allocation;
- the whole-file rewrite on acknowledgement, in the drain and in `jg-mail.sh`;
- the withdraw rewrite, in `bin/jg-wake-lib.sh` and the copy that
  `core/lead-wake` carried;
- the append of record-only rows to `.wake-settled`;
- the queue's append-recovery marker call and `_jg_wake_append_recovery_restore_locked`;
- `retire_unconsumable_rows_locked` and the `.wake-queue.ack.*` scratch, because a
  row the renderer writes always carries a sequence.

## What stays, and why

- **The acknowledgement generation handshake.** `--ack-through N
  --recovery-generation G` is printed into supervisor status lines, and
  `bin/jg-watch-arm.sh` takes a handover snapshot through the same marker; the
  command a live task is told to run carries the generation, so removing it is a
  separate change to that contract.
- **The actor grant files** (`.main-eligible-rows`, `.branch-eligible-rows`): they
  are the consumer's own bookkeeping about which rows it was handed, not the
  queue's storage.
- **The inbox record files and the want/have dedupe.** The record file is the
  worker-facing contract (`mv NN.msg handled/`), and the dedupe answers with an
  existing record path that the bus event does not carry.

## Test

`tests/jg-wake-queue-live.test.sh` starts a throwaway server and proves the cycle
that matters: a raise reaches the read model with the server's sequence, the drain
presents it and its acknowledgement removes it from the bus and from the read
model, a record-only row lands in the record model, a withdraw removes only its
own row, and an inbox record is raised at the writer and acknowledged when its
file leaves the inbox. It gate-skips when the server or the client is missing.
