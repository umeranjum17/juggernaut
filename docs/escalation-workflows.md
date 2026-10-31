# The escalation ladders and wait timers as a workflow definition, in shadow

Migration step 5c. The stuck-worker ladder is shell today: the owner alert, the
escalation, the board card, the re-alert cadence, the pause cadence and the
wait-source priority are rebuilt by hand inside
`core/wait-timers/bin/jg-wait-timers-lib.sh`, and `procevent`,
`ask-default`, `lead-wake`, `fleet-stall`, `nm-drain` and `merge-on-green` each
carry a copy of the same shape. The decided shape is one workflow definition with
timers and external events, configured rather than coded, so a new rung or
threshold is a config line plus a test and never a core code change. This step
puts that definition beside the code and proves it fires the same rung at the
same time for the same key.

Nothing switches here. `jg_wait_timers_tick` stays authoritative,
`bin/jg-escalation-workflows.sh` writes nothing into the file path it reads, and
the shadow record it keeps is its own.

## What runs

- `core/bus/workflows/escalation-wait-timers.json` is the definition: the rungs, the
  timer each rung fires on, each timer's seconds and the environment name it
  answers to, the ladder a wait class uses, the re-alert cadence, the wait-source
  priority and the episode key template. A home may override the whole file at
  `config/escalation-workflows.json` or with `JG_ESCALATION_WORKFLOW`.
- `core/bus/dapr/resiliency.yaml` is the same workflow's Dapr side: the
  retry and timeout policy for one rung delivery. No Dapr worker exists in this
  step, so it ships unloaded, beside the definition it belongs to.
- `bin/jg-escalation-workflows.sh tick` is the shadow. Once per watcher poll, for
  every open authoritative episode, it appends the rungs the definition says
  should already have fired to `$STATE/escalation-workflows.jsonl`, with the time
  the authoritative record shows the rung fired (`0` while it has not). A home
  turns it on with `config/escalation-workflows`, the same way `config/wake-bus`
  turns the wake mirror on. Off costs one file test, and a shadow that cannot
  read its definition never fails or delays a poll.
- `bin/jg-escalation-workflows.sh parity` is the proof, and
  `bin/jg-escalation-workflows.sh show` prints the definition in force with every
  timer's effective value.
- Facts are not policy and stay where they are: a status log, a wait source, the
  pause-until token and the captain hold are read by the same shared libraries
  the ladder code reads them with (`jg-classify-lib.sh`, `jg-wake-lib.sh`,
  `jg-backend.sh`). Code gathers facts, the definition decides.

## The ladder, as configuration

One episode per waiting lane, keyed by home, task, generation and source:
`waiting-timer-<home>-<task>-g<generation>-<source>`. Time starts at the first
observation, survives a watcher restart, and the definition owns every interval.

| rung | timer | fires at | delivered as (the code's own word) |
| --- | --- | --- | --- |
| owner | `owner`, 120s | `since + 120` | a wake to the actor, `…-owner` |
| escalate | `escalate`, 300s | `since + 300` | a lead home reports to Main; Main is woken, `…-escalation` |
| card | `card`, 600s | `since + 600`, main home only | one board card under `<key>-card` |
| re-alert | `re-alert`, 600s | every 600s after the last rung fired | a wake, `…-owner-again` or `…-main-again`, plus the card re-posted |

A declared pause is a different ladder: its owner rung rides the pause cadence
(14400s), its re-alert rides the same cadence, it never escalates and never
reaches the board. A captain hold or a pause whose `until` has not passed arms no
episode at all.

The wait-source priority is the definition's too: a blocked Herdr agent, then a
permission prompt, a picker question, a quota banner, a provider error, a silent
pane, a lead whose own supervision is down, a green PR left unmerged, then an own
open `blocked`/`needs-decision` decision, then a declared pause. The five
`fresh` sources lapse on the watcher's freshness bound; `supervision` does not.

Every timer answers to the environment name the current code reads
(`JG_WAIT_ALERT_SECS` and its siblings) before its own default. `show` prints the
value in force, so a drift between the shell default and the definition is
visible without running anything, and the parity replay would report it as a
difference, because it gives each side its own numbers.

## The parity contract

`bin/jg-escalation-workflows.sh parity [--home DIR] [--days N]` replays recorded
ladder events through both paths and compares one row per rung fired:

```
<key>	<rung>	<epoch>
```

Both sides run on the same replayed instants, in one order, over one replayed
home. The current side is the real `jg_wait_timers_tick` from the waiting-state library,
with its delivery stubbed and its clock replayed: every rung it would deliver is
one row, and the episode bookkeeping the real wake does after a delivered output
still runs, so the ladder's own state machine is unchanged. The new side is the
definition's engine over the same facts; it keeps its own episodes and its own
fired-rung times. A plain `diff` decides, so "the same rung" includes the same
episode key, the same rung name and the same second.

A recorded event is what the record carries and nothing more:

| record | event |
| --- | --- |
| a `state/<task>.status` line | the declaration at its own `[at=<epoch>]` stamp |
| a `state/.wait-sources/<task>.<source>` file | one sighting at the file's mtime |
| a `state/<task>.meta` | the lane's window and harness, with its endpoint made inert |

`--corrupt` reruns the replay on the new path alone with the arming time of one
recorded event shifted by one second. The same diff must then report a
difference; a run that stayed green would mean the check proves nothing. The
command exits non-zero in that case.

### What it does not prove

- The runtime's blocked-agent source. A blocked Herdr agent is a live fact with no
  durable per-rung record, so a replay never carries one. A switch wires that
  source to the runtime's own event.
- The waiting-state ladder's three sibling ladders in the same file: the parent
  relay, the stalled-backlog ladder and the green-PR poll keep their own timers
  until their own slices. This definition covers the waiting-state and pause
  ladders and the wait sources that feed them; a green PR reaches it as the
  `greenpr` wait source once that poll writes one.
- The rest of the migration row: the `procevent`, `ask-default`, `lead-wake`,
  `fleet-stall`, `nm-drain` and `merge-on-green` timers are separate ladders with
  separate events, and the poll timers they keep as `*.pr-poll` registrations are
  recorded but not replayed here.
- A lead home's parent-channel delivery. The replay home is a Main home, so the
  escalation rung is compared, not the transport it uses.
- The board's own state. The card rung is compared as a fire, not as a card on
  the board.
- A new supervisor session's re-presentation (`last=1` in the record), which
  fires every open wait at once on the first tick of a new session.
- One timing normalisation: the replay evaluates every lane at each instant,
  where a real poll ends at the first fire and continues on the next poll. A fire
  can therefore be up to one poll earlier here than in production, identically on
  both sides.
- Keys in the replay carry the replayed home's hash, not the recorded home's, so a
  shadow record can never collide with a live one.

## Measured

Measured on this branch with `wc -l` and the function spans named here; nothing
below is an estimate.

Current path, the ladder and its timers as they are:

- 663 lines, `core/wait-timers/bin/jg-wait-timers-lib.sh`. 363 of them are the
  ladder this definition models: 266 in `jg_wait_timers_tick` (the rung
  decision), 25 the board card, 19 plus 19 the two delivered-wait sources, 34 the
  record format, identity, parent report and episode end, 25 the rest of its
  small helpers. The other 201 are the three sibling ladders in the same file (76
  the parent relay, 63 the stalled-backlog ladder, 51 plus 11 the green-PR poll),
  and 99 are header and compatibility shim.

New path, the same ladder as configuration:

- 137 lines, `core/bus/workflows/escalation-wait-timers.json` (the definition).
- 31 lines, `core/bus/dapr/resiliency.yaml` (retry and timeout policy).
- 724 lines, `bin/jg-escalation-workflows.sh`: 53 the header contract, 88 the
  definition reader and rung helpers, 63 the facts, 29 `show`, 39 `tick`, 134 the
  two runners and their fired-rung bookkeeping (`wf_step` alone 71), 125 the
  replay machinery (the snapshot, the event collection, the replayed home, the
  replayed clock, the step scheduler and the diff), 82 the `parity` command, 55
  library loading, 15 `main`, and 41 of section comments and blank lines.

So the definition is 168 lines against the 363 lines of ladder it expresses, and
this step's shadow engine that runs it is 189 more (134 engine plus 55 library
loading); the replay scaffolding belongs to the proof, not to a switch. That engine is a stand-in:
the stack report measured 101 lines for the Dapr workflow worker its probe ran, so
a switch lands nearer 168 + 101 = 269 lines against 363: about 95 fewer lines for
this ladder, and, which is the actual objective, one definition plus one test for
the next rung instead of a change inside a 266-line decision loop.

Replay measured on this branch, over this home's last 7 days: 229 recorded events,
246 rungs compared at 363 replayed instants, 0 differences, in 7m01s. The same
replay with one event's arming time shifted by one second on the new path reports
10 changed lines, which are exactly that episode's five rows moved by one second,
in 9m37s: the check is not vacuous.

## Test

`tests/jg-escalation-workflows.test.sh` builds a home from recorded-shaped
events and proves the check in both directions: parity is green with a count of
events and rungs and zero differences, and the same check fails once one event is
corrupted on the new path. It also proves the shadow `tick` records the rungs the
definition predicts, leaves the authoritative episode record untouched, and does
nothing at all until the home turns it on.

## Replaying a real home

```sh
bin/jg-escalation-workflows.sh parity --home "$HOME" --days 7
bin/jg-escalation-workflows.sh parity --home "$HOME" --days 7 --corrupt
```

The replay writes only inside its own temporary directory, so it never touches
the home it is reading. `JG_ESCALATION_KEEP=1` keeps that directory and prints
its path, for inspecting the rows both sides produced.
