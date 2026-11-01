# A pending reply as a durable workflow, in shadow

Migration step 5d. A pending reply is a hand-rolled wait-for-reply-or-timeout: a record file, a grace window measured from a turn's completion, a busy/idle observation to find that completion, one recovery repost with its own reconciliation ladder, a second grace window, and then one escalation. The decided shape is a durable workflow: the waiter is an instance, the reply is the event that resumes it, the timeout is a timer that survives a restart, and the repost-then-escalate ladder is the workflow's own activity loop. This step runs that wait on the bus beside the record and proves the event path reaches the record path's decision - the same reply settles the same waiter, and the same timeout is bound to the same deadline.

Nothing switches here. Both paths run at once, the records stay authoritative, and `bin/jg-reply-bus.sh` writes nothing into the record path: no record, no status line, no repost, no escalation.

## What runs

- `core/bus/workflows/pending-reply.json` is the workflow definition, and it is the one owner of the model: the instance key, the four events, the two stages with the anchor each timer measures from, the activity each timeout runs with its retries, the terminal states, the subjects, the grace default and the retention. A home may override it at `config/bus/workflows/pending-reply.json`.
- `bin/jg-reply-bus.sh sync` reads one home's records and publishes every fact it holds as an event on the `JG_REPLY` stream (`jg.reply.>`), file storage with `max_age` from the definition. A fact's message id is its key plus a digest of its body, so a repeat publish is a server no-op and a changed fact supersedes the earlier one.
- A home turns the mirror on with `config/reply-bus`, and `bin/jg-watch.sh` then runs one `sync` per poll immediately after the pending-reply tick, followed by one `tick` of the engine, so both paths really run at once. Off costs one file test.
- The mirror never becomes a dependency: a missing client, a missing server, or any transport failure prints `skip: ...` or is swallowed, and the record path behaves exactly as before.
- `$STATE/reply-bus.jsonl` is the shadow record: one line per published fact, written after the publish. The record path is the durable record of the fact, so a publish that fails records nothing and the next sync tries again.

## The engine, in shadow

`bin/jg-reply-engine.sh` is the definition's engine. It folds the event log into
one state per waiter, decides what the definition says each stage should do, and
- in this step - only records the decision. It sends no repost, opens no
escalation, closes nothing and writes no record; `bin/jg-pending-reply-lib.sh`
stays the live path.

- `docs` prints one tab-separated state line per waiter: the instance, its task
  and grace, its delivery state and epochs, each stage's timer, what each fire
  returned, and the answer.
- `decide <log> <epoch>` prints the rows the definition says to take at one
  instant: `arm <id> <stage> <deadline>`, `repost <id> <deadline>`,
  `escalate <id> <reason> <deadline|->`, `answer <id> <epoch> <via>`. A decision is
  bound to the deadline its timer derives, never to the instant a poll noticed it.
- `tick` is the watcher's slot for it: fold, decide every waiter at one instant,
  and append what it would do to `$STATE/reply-bus-decisions.jsonl`.
- `replay [<log>] [--corrupt]` walks a recorded log instant by instant, compares
  the decision at each instant with the decision the record path took from the
  same facts, and names both rows when they disagree.

The store is `$STATE/reply-bus.jsonl`, one event per line as
`<key>\t<digest>\t<json>`, append-only, folded with the last event per key. It is
an interim transport, never a second store: `event_stream` in
`bin/jg-reply-engine.sh` is the single seam between the transport and the model,
and its one line - today `cut -f3` over that file - becomes the JetStream
subscription on the same subjects when a home runs a bus. The writer side makes
the same promise: `bin/jg-reply-bus.sh` appends the event first and mirrors the
identical line onto JetStream only when a server answers, so a missing bus costs
the replica, never the event.

Measured over the main home's recorded traffic (2,367 waiters created in the last
168 hours), with the log built by mirroring those records:

```text
reply engine replay: recorded_events=9890 waiters=2367 replayed_instants=6104 decisions_compared=3265 differences=0 held_by_a_reply=33 activity_lateness_s=0..588 activities_over_poll_ceiling=0 escalations_without_a_timeout=4
```

`held_by_a_reply=33` is the one named asymmetry, not an unexplained difference:
the record path resolved on its next poll before its deadline activity ran, while
the engine decides at the deadline. Slice B makes the reply an event of its own,
which settles the instance before that activity; until then the count is reported
rather than hidden. `escalations_without_a_timeout=4` is the delivery-failure
branch the record path models with no timer at all, and the engine decides it from
the repost's own outcome. `--corrupt` moves every replayed grace by one second and
reports 947 differences, so a green replay is never vacuous.

## The event model

One event per fact of one waiter, and the fold keeps the last event per key:

| fact | event | key | what it says |
| --- | --- | --- | --- |
| the waiter exists | `waiter` | `waiter/<id>` | its task and the grace it waits for |
| a stage's timeout is armed | `timer` | `timer/<id>/<stage>` | the anchor and the grace; the deadline is derived by whoever reads it |
| that timeout fired | `fire` | `fire/<id>/<stage>` | the epoch the record shows for it |
| the reply settled it | `answer` | `answer/<id>` | the epoch it resolved and how the report came |

An answer or a fire only counts for a waiter the stream holds, so a reply can never settle a waiter that does not exist, and an instance can never be invented by its own reply.

The record path's facts and the workflow's stages are read from the same definition: the stages name the record field each timer measures from and the field that records its firing (`core/bus/workflows/pending-reply.json`). That is deliberate - a switch replaces those fields with the workflow's own state, and naming them here keeps the model and the record from drifting apart silently.

## The parity contract

`bin/jg-reply-bus.sh parity [--since-hours N]` replays the window through both paths and compares the consumer result row by row:

```
reply <id> waiter <task> <grace>
reply <id> timer  <stage> <deadline|none>
reply <id> fire   <stage> <epoch>
reply <id> answer <epoch> <via>
```

The deadline is derived on each side from the anchor and the grace the definition names, so a mixed-up anchor, grace or unit shows up as a difference instead of hiding. "The same reply settled the same waiter" is the `answer` row, and "the same timeout is bound to the same deadline" is the `timer` row for the same stage of the same instance.

The record path is live while the comparison runs, so the check scans it twice, syncs between the scans, and compares only the rows both scans agree on. Rows that appeared or changed mid-run are reported as `churned` instead of being counted as a difference they are not.

`--corrupt` republishes one existing event with a tampered field under a fresh message id. The fold presents it last, so a corrupted event must produce a difference; a run that stayed green after that would mean the check is vacuous.

## Measured, on a real home

Replayed read-only over the main home's records (`~/firstmate`), 7-day window, `--since-hours 168`, on 2026-11-01:

```text
reply shadow parity: homes=1 events_compared=9770 differences=0 churned=0 timers_armed=479 timers_fired=433 max_lateness_s=588 fire_without_timer=3 fire_before_deadline=0
```

That is 9,770 rows over 2,335 recorded waiters, 2,332 of which a correlated reply settled, with 479 timers armed and 433 fired. Zero differences. The same check with `--corrupt` reported `differences=2` and named the tampered field:

```text
-reply	firstmate:bde6b403/00664ee3c961fd0a	waiter	firstmate-addons	120
+reply	firstmate:bde6b403/00664ee3c961fd0a	waiter	corrupted-by-the-parity-test	120
reply shadow parity: homes=1 events_compared=9770 differences=2 churned=0 timers_armed=479 timers_fired=433 max_lateness_s=588 fire_without_timer=3 fire_before_deadline=0
```

Two numbers in that line are findings, not noise:

- `max_lateness_s=588` is how late the record path fires a timeout: it fires on the watcher's poll cadence, so a timeout can land up to about ten minutes after its deadline. A workflow timer fires at the deadline. Parity is therefore on the deadline, and the lateness is measured and reported rather than compared, because a timer that fired at its deadline is the change the switch delivers.
- `fire_without_timer=3` are the three records that escalated through the delivery-failure branch (`recovery_delivery_outcome=failed` or `unknown`): a repost that could not be delivered escalates with no timer at all. A workflow models that as a failed activity, not a timeout, so those three are named here as an asymmetry the switch has to carry, not as a parity pass.

## Measured lines each side

Measured with `wc -l` and the function spans of each file; nothing below is an estimate.

The workflow path, `bin/jg-reply-bus.sh` at 495 lines plus the 42-line definition, 537 lines:

- 165 for the mirror, in 14 functions: the definition reader, the record scan, the fact-to-event builders, the shadow record and the publish.
- 133 for the replay, in 8 functions: the record rows, the two scans and the churn, the fold, the compare, the lateness tally and `--corrupt`. 133 of the 537 exist only for the replay.
- 197 for the contract header, the argument handling and the config resolution.

The record path, the wait and timeout machinery a workflow replaces inside `bin/jg-pending-reply-lib.sh` (1,722 lines total), 1,047 lines:

- 46 for the record's own location, clock and read/write (`now`, `grace_secs`, `dir`, `path`, `get`, `set`).
- 181 for the delivery-evidence ladder: the confirmation marker, delivery confirmation and reconciliation, the unknown and failed branches, and the undelivered reset.
- 125 for finding the reply: the status-line scan, its signature cache, the `via` classification and the idempotent resolve under its lock.
- 116 for finding the turn completion that starts the timer: the busy/idle observation, its fallback, the backend observation mapping and the explicit completion marker.
- 141 for the recovery repost: the send under the lock, the sender identity, the finish and the reconciliation.
- 226 for the escalation: the payload, the durable decision line, opening and closing that decision, and the eligibility ladder.
- 212 for the poll: the per-record tick, the selection pass and the home-wide tick.

That is 1,047 record-path lines against 537 workflow-path lines, so a switch would remove about 510 lines net, and it would remove these mechanisms with them:

- the record file as the workflow's own state, and the lock that serialises a resolve against an escalation;
- the grace arithmetic and the busy/idle observation that finds the anchor;
- the delivery-confirmation marker and its reconciliation ladder, which become the delivery activity's result;
- the poll loop, because a reply event resumes the instance instead of a tick noticing it;
- and it would add the one thing the records cannot do: a timer that fires at its deadline instead of on the next poll.

The 163 lines that create and identify a request (`new_id`, `corr_token`, `extract_corr`, `text_has_corr`, `summarize`, `embed_corr`, `create`, the sighting encoding) stay: they are the correlation identity the switch still needs. So do the remote-channel watermark (38), the recovery message text (9), and the wrong-home detection (83), which are diagnosis and channel concerns rather than the wait itself. Callers of the removed functions - `bin/jg-send.sh`, `bin/jg-backlog-handoff.sh`, `bin/jg-teardown.sh`, `bin/jg-squad-lead-restart.sh`, `bin/jg-procevent-remote-reply.sh` - are not counted here; their lines move when the switch lands, not before.

## What it does not prove

The mirror is fed by the record path, so this proves the transport, the correlation and the decision half: ordering, dedupe, the fold, who a reply settles, and the deadline a timer is bound to. It does not prove the producer half; starting the instance at delivery instead of reading the record afterwards, and reading the reply event at its source, are what the switch itself adds.

It also does not run the durable engine. This replay executes the workflow's model in the fold over the stream; the runtime that hosts the timer across a restart (the slim Dapr runtime, `daprd`, over NATS) is what the switch adds, and the definition file is what such a host would run. No claim is made here that `daprd` ran for this step.

Finally, the record path's grace default still lives in the library (`JG_PENDING_REPLY_GRACE_SECS`, 120), while the definition carries the same number. A drift between them shows up as a `timer` difference on any record whose stored grace is empty, which is how this replay would catch it.

## Replaying a real fleet

```sh
# mirror every home that had traffic, without writing into those homes
for h in "$@"; do args+=(--home "$h"); done
JG_REPLY_BUS_SHADOW=on bin/jg-reply-bus.sh "${args[@]}" --record-dir /tmp/reply-bus sync
bin/jg-reply-bus.sh "${args[@]}" --record-dir /tmp/reply-bus --since-hours 168 parity
bin/jg-reply-bus.sh "${args[@]}" --record-dir /tmp/reply-bus --since-hours 168 parity --corrupt
```

`--record-dir` keeps the shadow record outside the mirrored home, so a fleet-wide replay never writes into a home it is only reading. `JG_REPLY_BUS_SHADOW=on` enables the mirror for the run without a `config/reply-bus` file in every home.

## Test

`tests/jg-reply-bus-parity.test.sh` starts a throwaway server on a free port, writes the record side with the production writers (`jg_pending_reply_create`, `jg_pending_reply_send_recovery`, `jg_pending_reply_try_resolve`, `jg_pending_reply_maybe_escalate`), and proves the check in both directions: an answered waiter, an escalated one and an open one produce the same twelve rows on both paths with zero differences, and one corrupted event on the workflow path fails the same check. The test gate-skips when `nats-server` or the `nats` client is missing; set `JG_NATS_SERVER` and `JG_NATS_BIN` to pin them. `tests/jg-reply-engine.test.sh` needs no server at all: it writes the event log by hand and proves the fold, each decision branch, a shadow tick that acts on nothing, and a replay that is green on a faithful recording and not green when the replayed grace moves.
