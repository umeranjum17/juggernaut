# auto-dispatch

Every watcher beat writes down which tickets this home would start by itself, with no model turn.
With the switch off (the default) it is watch only: it starts nothing, writes no brief and picks no route.
A week of its rows shows how often it agrees with what the leads started.
With the switch on it starts the tickets it would start, through `bin/jg-spawn.sh`.
It still writes no brief and picks no route: both come from the lead's approval.

`dispatch.sh check <jg-home>` is the watcher check.
It prints nothing, so it wakes no one.

## What it reads

- Free lanes: `config/lane-target` minus the ship and Recon lanes still working.
  A home with no lane target has none.
- The tickets `bin/jg-backlog.sh ready --spawnable` lists, plus every ticket with an approval record.
- The approval record `state/dispatch-approved/<id>`.
  Only `bin/jg-backlog.sh approve-dispatch <id> --harness <h> --model <m> --effort <e>` writes it.
  The command refuses in a worker session (`JG_TASK_ID` is set), so only the lead or the owner approves.
  A line such as `auto-dispatch: yes` typed into a ticket body is never read.

## Verdict for each ticket

The first reason that fits is the one written:

1. no approval record;
2. an open captain decision is linked to it (`bin/jg-captain-hold.sh blocking`; a failed read also stops it);
3. it is not spawnable now (held, taken by a lane, closed, or another home's project);
4. no brief at `data/<id>/brief.md`;
5. the approval record has no route;
6. no free lane is left.

A ticket that passes all six is a "would start" row, in list order, up to the number of free lanes.

## The file

`data/auto-dispatch/rows.tsv` is the one file it writes.
Each row is `<epoch><TAB><id><TAB>would start|skipped<TAB><route, or why>`.
A row is added only when a ticket's verdict changes, so a quiet beat writes nothing.

## Wiring

`wiring.sh [--dry-run] <jg-home>` installs the check, writes the shim `state/auto-dispatch.check.sh`, and registers it.
`unwiring.sh [--dry-run] <jg-home>` removes it; that is the rollback.
`bin/jg-host-wiring.sh` runs the wiring for each home.

## Test

`bash tests/jg-auto-dispatch.test.sh` runs the whole journey: 2 free lanes and 6 ready tickets, through the real `ready --spawnable` reader and the real `approve-dispatch`, then the switch on with a spawn stand-in that waits, fails or starts.
`tests/jg-spawn-lock-deferral.test.sh` runs the real `bin/jg-spawn.sh` against a locked task set (it needs `JG_BEADS_TEST_BD` and `JG_BEADS_TEST_DOLT`).

## The switch

`config/auto-dispatch` holds one word per home.
`on` makes the check act; anything else, or no file, leaves it watch only.
Removing the file is the rollback; the lane target and the quota gates stay in force either way.

## What it does with the switch on

For each "would start" ticket it runs `bin/jg-spawn.sh <task> projects/<project> --ticket <id> --mode <m> --yolo <y> --harness <h> --model <m> --effort <e>`, detached and wrapped by `dispatch.sh run`:

- the route is the one in the approval record (Claude Sonnet for the plan that built this);
- the mode is the brief's `Delivery contract: mode=` line, and yolo is the project's registered posture;
- the branch prefix is the one the brief's branch line names;
- the spawn's output is `data/auto-dispatch/<id>.log`, and the row is `starting`.

The spawn keeps its own refusals (owner asks, plan tickets with no recorded yes, quota, pool).
Before each start it asks `core/pool-reserve/reserve.sh admit` for a copy of the ticket's project (the lane limit and the two copies kept for a red fix). With no copy free the row says `no free copy`, nothing is spawned, the lead hears nothing, and a later beat starts it.
With the pool unreadable the row says `copy count unknown` instead (one row until the verdict changes), nothing is spawned, the lead hears nothing, and the next beat that can read the pool starts it.

## The spawn's result is the row

The launch is not the result.
When the spawn ends, the wrapper writes what it did into the start record `data/auto-dispatch/<id>.start.<attempt>`, and the next beat's row follows that record:

| The spawn | The result | The row | What happens next |
| --- | --- | --- | --- |
| exits 0 and the lane record `state/<task>.meta` is there | started | `started` | nothing: the lane counts itself |
| exits 75 (a full pool, no copy, the load, the capacity, a locked task set) | deferred | `deferred`, with the spawn's own words | the next beat with a free lane and a free copy starts it again, as the next attempt, under the same approval; the lead hears nothing |
| exits with any other code, or exits 0 and leaves no lane record | refused | `spawn failed`, with the spawn's last line | named to the lead once; not tried again until the lead approves the ticket anew |

A restart creates no duplicate:

- Before a start the check asks the ready state again. A lane record already there (another path started the ticket since the list was read) means the ticket runs, and nothing is spawned. A start record with no result is a start in flight, and nothing is spawned.
- Each attempt is claimed by creating its record with noclobber, so two check runs at once, or a restart, start the ticket once.
- A wrapper that died leaves a record with no result. After 10 minutes the lane record settles it: there is one, the ticket started; there is none, it failed.

`core/machines/tables/dispatch-start.tsv` is the table of these states (ready, starting, started, deferred, refused), and `bin/jg-machine.sh show dispatch-start <id>` reads one ticket.

## What the lead hears

Switch on, one line per beat names the tickets that newly need the lead: no approval record, no brief, no route, no delivery contract, or a failed start.
`data/auto-dispatch/told.tsv` keeps each ticket from being named twice for the same reason.
A ticket held by an open decision, or one waiting for a lane, is not named: those clear without the lead.

## Ready work that does not start

Switch on, a ticket the check may start (a free lane, all six reasons passed) that has no running start 10 minutes after its refusal raises the `ready-idle` alert.
The alert is raised through `bin/jg-alert.sh` (its table owns the timer and the rung), printed as one wake line, and resolved when a start takes.
Watch only raises nothing.
`core/fleet-stall/fleet-stall-check` no longer reports a home with the switch on as an idle lead with ready work: that home starts its own tickets, and this alert names the failure.

## Follow-up (not in this slice)

- A scout start (a brief with no delivery contract line is skipped today).
- A spawn failure is read from the missing lane record after 10 minutes; reading the spawn's own exit would be faster.
