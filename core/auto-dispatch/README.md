# auto-dispatch

Every watcher beat writes down which tickets this home would start by itself, with no model turn.
This is the watch-only stage: it starts nothing, writes no brief and picks no route.
The lead still starts the work.
A week of its rows shows how often it agrees with what the leads started.

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

`bash tests/jg-auto-dispatch.test.sh` runs the whole journey: 2 free lanes and 6 ready tickets, through the real `ready --spawnable` reader and the real `approve-dispatch`.

## Follow-up (not in this slice)

Slice 16 makes the check act: it spawns an approved ticket through `bin/jg-spawn.sh` behind a `config/auto-dispatch` switch.
