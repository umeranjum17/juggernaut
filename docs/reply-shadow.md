# A pending reply as a durable workflow on the bus

Migration step 5d. A pending reply is a hand-rolled wait-for-reply-or-timeout: a
record file, a grace window measured from a turn's completion, a busy/idle
observation to find that completion, one recovery repost with its own
reconciliation ladder, a second grace window, and then one escalation. The
decided shape is a durable workflow: the waiter is an instance, the reply is the
event that resumes it, the timeout is a timer that survives a restart, and the
repost-then-escalate ladder is the workflow's own activity loop.

The switch has landed. A waiter's facts are events on this home's JetStream bus,
every writer publishes them as it writes, and the record file is their projection
- the same keys in the same order every reader already opens. The workflow
definition decides, and its engine acts on that decision: one recovery repost, one
escalation, one unknown-delivery mark, the escalation close. The hand-rolled poll
that used to do this - the delivery-marker ladder, its reconciliation, the phase
walk in `tick_one` and the selection pass - is deleted. The record file itself
stays for one more slice, because it is still every reader's interface.

## What runs

- `core/bus/workflows/pending-reply.json` is the workflow definition, and it is
  the one owner of the model: the instance key, the five events, the two stages
  with the anchor each timer measures from, the activity each timeout runs with
  its retries, the terminal states, the subjects, the grace default and the
  retention. A home may override it at `config/bus/workflows/pending-reply.json`.
- Every writer of `state/pending-replies/<corr>` publishes through
  `bin/jg-pending-reply-lib.sh`: the creation, the delivery attempt and its
  confirmation or its unknown aging, the undelivered reset, the discard, each
  turn's completion, and the reply. One publish carries every fact that record
  holds, so a writer never has to know what the bus already has; the message id
  is the fact's key plus a digest of its body, so a repeat is a server no-op and
  a changed fact supersedes the earlier one.
- A fact is published only when a bus answers. A home with no bus keeps
  recording and keeps serving the guard: the publish skips, and the next write to
  that waiter carries its whole state to the bus again.
- `bin/jg-reply-bus.sh project` writes the fold back as the record files. That is
  what makes the stream the authority: destroy the records and rebuild them from
  the bus, byte for byte, marker included.
- `bin/jg-reply-bus.sh log` prints the stream in the engine's log format, so the
  engine folds, decides and replays the bus itself instead of a file beside it.
- `bin/jg-watch.sh` runs `bin/jg-reply-engine.sh tick --act` once per poll: the
  engine decides, the library acts, and the decisions it acted on are appended to
  `$STATE/reply-bus-decisions.jsonl` as the trace.

## The projection

The record stays exactly what it was, because every reader and every test reads
it as it did: `schema`, `corr_id`, `task_id`, `parent_home`, `parent_status`, the
scan signature, the summary, the epochs, the phase, the wrong-home sightings and
the grace. The writer's own bytes are carried on the `waiter` event's `record`
field, so the projection is a byte copy and not a re-encoding someone has to keep
in step with the writer.

The delivery attempt is the record's own `delivery_attempted_epoch`; there is no
separate marker file any more. An attempt that never confirms is what the engine
ages into an unknown delivery, and a confirmation clears the attempt and sets
`delivered_epoch`. A `discard` removes the record and stops the id counting in
every fold, so a discarded request cannot come back on the next projection.

When the bus cannot be reached, the projection is still written and the guard
still works; what a skipped publish costs is the rebuild of a waiter that is
never written again. That is the honest reading of a transport that is optional
per write and authoritative per stream.

## The engine

`bin/jg-reply-engine.sh` is the definition's engine. It decides what the
definition says each stage should do, and - in `tick --act` - it performs that
decision through `bin/jg-pending-reply-lib.sh`: one recovery repost, one
escalation, one unknown-delivery mark, the escalation close. It never invents an
action: every row it acts on is a row the definition took.

- `docs` prints one tab-separated state line per waiter: the instance, its task
  and grace, its delivery state and epochs, each stage's timer, what each fire
  returned, and the answer.
- `decide <log> <epoch>` prints the rows the definition says to take at one
  instant: `arm <id> <stage> <deadline>`, `repost <id> <deadline>`,
  `escalate <id> <reason> <deadline|->`, `answer <id> <epoch> <via>`. A decision is
  bound to the deadline its timer derives, never to the instant a poll noticed it.
- `tick` records what the definition would do at one instant, and does nothing.
  `tick --act` is the live slot: for every waiter it first observes and resolves -
  the correlated reply line, the mate-home repairs, the endpoint's busy/idle turn
  completion - then asks for the decision from the record that observation just
  wrote, so an armed timer and its repost land in the same poll. The rows it acts
  on are appended to `$STATE/reply-bus-decisions.jsonl`.
- `decide-stdin [<epoch>]` is how the library asks for that decision: doc lines in,
  decision rows out, one instant. `bin/jg-reply-bus.sh docs <record>` prints the
  doc line for a record, in the same field order `docs` prints for a log.
- `replay [<log>] [--corrupt]` walks a recorded log instant by instant, compares
  the decision at each instant with the decision the record path took from the
  same facts, and names both rows when they disagree.

## The event model

One event per fact of one waiter, and the fold keeps the last event per key, in
stream order:

| fact | event | key | what it says |
| --- | --- | --- | --- |
| the waiter exists, and every later record state | `waiter` | `waiter/<id>` | its task, grace, delivery state and its record text |
| a stage's timeout is armed | `timer` | `timer/<id>/<stage>` | the anchor and the grace; the deadline is derived by whoever reads it |
| that timeout fired | `fire` | `fire/<id>/<stage>` | the epoch the record shows for it |
| the reply settled it | `answer` | `answer/<id>` | the epoch it resolved and how the report came |
| it is gone | `discard` | `discard/<id>` | the waiter was dropped, so every fold stops counting it |

The delivery facts the record path names are the `waiter` event's `state`:
`sent`, `attempted`, `confirmed`, `unknown`. A reset is a `waiter` event whose
state and phase are back to the start, and a turn's completion is its `timer`
event. An answer or a fire only counts for a waiter the stream holds, so a reply
can never settle a waiter that does not exist, and an instance can never be
invented by its own reply.

The record path's facts and the workflow's stages are read from the same
definition: the stages name the record field each timer measures from and the
field that records its firing. That is deliberate - a switch replaces those
fields with the workflow's own state, and naming them here keeps the model and
the record from drifting apart silently.

## The consistency contract

`bin/jg-reply-bus.sh parity [--since-hours N]` reads the record files and the
stream and compares the consumer result row by row:

```
reply <id> waiter <task> <grace>
reply <id> timer  <stage> <deadline|none>
reply <id> fire   <stage> <epoch>
reply <id> answer <epoch> <via>
```

The deadline is derived on each side from the anchor and the grace the definition
names, so a mixed-up anchor, grace or unit shows up as a difference instead of
hiding. Zero differences means the projection is faithful: everything a record
says, the stream says, and nothing the stream says is missing from the records.

The records are live while the comparison runs, so the check scans them twice and
compares only the rows both scans agree on. Rows that appeared or changed mid-run
are reported as `churned` instead of being counted as a difference they are not.

`--corrupt` republishes one existing event with a tampered field under a fresh
message id. The fold presents it last, so a corrupted event must produce a
difference; a run that stayed green after that would mean the check is vacuous.

## Measured

Replayed read-only over the main home's records (`~/firstmate`), 2,367 waiters
created in the 168 hours before the recording, published onto a throwaway
JetStream server by the shipped backfill (9,890 events), and read back through
`log`:

```text
reply engine replay: recorded_events=9890 waiters=2367 replayed_instants=6104 decisions_compared=3265 differences=0 held_by_a_reply=33 activity_lateness_s=0..588 activities_over_poll_ceiling=0 escalations_without_a_timeout=4
```

That is the slice A decision replay, unchanged, now over the bus: the same 3,265
decisions, zero differences. `held_by_a_reply=33` is the one named asymmetry, not
an unexplained difference: the record path resolved on its next poll before its
deadline activity ran, while the engine decides at the deadline.
`escalations_without_a_timeout=4` is the delivery-failure branch the record path
models with no timer at all, and the engine decides it from the repost's own
outcome. The same replay with every grace moved by one second reports 947
differences, so a green replay is not vacuous.

The records and the stream, compared row by row over the same corpus:

```text
reply bus parity: homes=1 events_compared=9890 differences=0 churned=0 timers_armed=480 timers_fired=430 max_lateness_s=588 fire_without_timer=4 fire_before_deadline=0
```

`max_lateness_s=588` is how late the record path fires a timeout: it fires on the
watcher's poll cadence, so a timeout can land up to about ten minutes after its
deadline. Parity is on the deadline, and the lateness is measured and reported
rather than compared. `fire_without_timer=4` are the records that escalated
through the delivery-failure branch: a repost that could not be delivered
escalates with no timer at all, which the engine models as a failed activity.

One waiter then went round the whole way: created, delivered, its turn completed
and its reply found by the writers, published as its facts, its record files
destroyed, rebuilt from the stream alone, and compared byte for byte - identical.
A discarded waiter left the same way: zero rows in the stream view, its record
gone from the projection after the rebuild.

## Measured lines each side

Measured with `wc -l` and the function spans of each file; nothing below is an
estimate.

The workflow path, `bin/jg-reply-bus.sh` at 709 lines, `bin/jg-reply-engine.sh` at
508, plus the 43-line definition, 1,260 lines:

- 268 for the transport in `bin/jg-reply-bus.sh`, in 18 functions: the definition
  and config readers, the record scan, the fact-to-event builders, the publish and
  the discard, the doc line a decision is taken from, and the backfill.
- 199 for the fold and the commands that prove it, in 9 functions: the stream dump,
  the fold, the projection, the log, the record rows, the two scans and the churn,
  the compare and `--corrupt`.
- 218 for that file's contract header, argument handling and config resolution.
- 349 for the engine's own body, in 18 functions: its fold, the decision, the
  acting tick, the shadow tick and the replay.
- 226 for the engine's contract header and argument handling.

`bin/jg-pending-reply-lib.sh` is 1,489 lines now, and what it still holds is the
part the next slice cannot do without: the correlation identity, the status-line
resolve with its document/`via` classification, the recovery message and its
transport, the escalation payload and the line and close lifecycle, wrong-home
detection, the remote watermark, the parked-home gate, the endpoint observation
that finds a turn completion, and the one record write seam every writer publishes
through.

What this slice deleted, and the mechanisms it deleted with them:

- the delivery-confirmation marker file and its ladder: nine functions, the
  prepare/confirm/reconcile/reset/unknown paths, and the aging that turned an
  attempt into an unknown delivery. The attempt is one record fact now
  (`delivery_attempted_epoch`), and the definition decides the unknown delivery
  from it;
- the poll's hand-written decision walk: `jg_pending_reply_tick_one`, the
  selection pass, the delivery reconciliation each of them called, and the phase
  ladder in `jg_pending_reply_tick`;
- the parent-status scan cache: the resolve scans the line on every poll, and a
  resolve is idempotent, so there is nothing to invalidate;
- every per-correlation lock: `try_resolve`, `confirm_delivery`,
  `reconcile_delivery`, `reset_known_undelivered`, `maybe_escalate`,
  `close_escalation`, `send_recovery`, and teardown's retire. One acting tick per
  home is the only writer of these records, and the reply is read immediately
  before any action, so the lock serialised a single writer against itself;
- teardown's pending-reply retirement: the record and marker pair became one
  published `discard` plus the record's removal, and the handoff-wake retire keeps
  its staged rollback with nothing left to stage but the record and its marker.

`bin/jg-send.sh` lost the two-branch delivery-commit message (there is no
recoverable marker to fall back to, so a lost commit is one degraded condition),
and `bin/jg-reply-engine.sh` gained the acting tick and `decide-stdin`.

## The upgrade, and what it costs

A home that updates carries records the bus has never seen. `bin/jg-reply-bus.sh
--home <dir> sync` publishes every fact every record holds, which is the one-time
backfill; after that the writers keep the stream current. Without it a home still
works - each waiter reaches the bus on its next write - but the stream cannot
rebuild a waiter nothing writes again. `sync` is idempotent, so it is also the
repair to run after a stream is lost.

Publishing is a client call per fact: a write republishes every fact its record
holds, at most seven, and the server keeps only the ones whose body changed. That
is cheap at the watcher's cadence and visible when a home writes thousands of
waiters at once, which is what the backfill is; 2,367 waiters took a few minutes
on this machine.

## What it does not prove

It does not delete the record file: every reader still opens it, so the projection
stays until the next slice points them at the stream.

It does not run the durable runtime. This replay executes the workflow's model in
the fold over the stream; the runtime that hosts the timer across a restart (the
slim Dapr runtime, `daprd`, over NATS) is what a later slice adds, and the
definition file is what such a host would run. No claim is made here that `daprd`
ran for this step.

It does not re-decide the grace. The record path's grace default still lives in
the library (`JG_PENDING_REPLY_GRACE_SECS`, 120) and the definition carries the
same number; a drift between them shows up as a `timer` difference on any record
whose stored grace is empty, which is how the replay would catch it.

## Replaying a real fleet

```sh
# publish every home's records, compare them with the stream, then replay it
for h in "$@"; do args+=(--home "$h"); done
bin/jg-reply-bus.sh "${args[@]}" sync
bin/jg-reply-bus.sh "${args[@]}" --since-hours 168 parity
bin/jg-reply-bus.sh "${args[@]}" --since-hours 168 log > /tmp/reply-bus.jsonl
bin/jg-reply-engine.sh replay /tmp/reply-bus.jsonl
```

`sync` writes nothing but events, so a fleet-wide backfill never changes a home's
records. `project` does write records, so run it against one home at a time and
only when you mean to rebuild them.

## Test

`tests/jg-reply-bus-parity.test.sh` starts a throwaway server on a free port and
writes with the production writers (`jg_pending_reply_create`,
`jg_pending_reply_mark_delivered`, `jg_pending_reply_send_recovery`,
`jg_pending_reply_try_resolve`, `jg_pending_reply_maybe_escalate`,
`jg_pending_reply_discard_undelivered`), so their own publishes are what reaches
the bus. It then proves four things: no interim log was written beside the bus
and a discarded waiter leaves the stream view; the records rebuilt from the bus
are byte-identical to the ones the writers wrote; the records and the stream
produce the same twelve rows for three live waiters with zero differences; and
one corrupted event fails that same check. The test gate-skips when `nats-server`
or the `nats` client is missing; set `JG_NATS_SERVER` and `JG_NATS_BIN` to pin
them. `tests/lib.sh` points every suite that starts no bus of its own at a closed
address, so a test never publishes into this machine's stream.
`tests/jg-reply-engine.test.sh` needs no server at all: it writes the event log by
hand and proves the fold, each decision branch, a shadow tick that acts on
nothing, and a replay that is green on a faithful recording and not green when the
replayed grace moves.
