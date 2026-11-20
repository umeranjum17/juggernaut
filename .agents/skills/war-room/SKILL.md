---
name: war-room
description: Use when the captain invokes /war-room or /council with a hard design or problem - several deep Recons and critics, then one plan in work orders.
user-invocable: true
metadata:
  internal: true
---

# /war-room

## What it does
Runs independent deep Recons from different angles, a critic for each, and one synthesis that writes the report, the work orders and `orders/plan.json`.
`/war-room lite <problem>` runs only the synthesis Recon, its critic and the dry run.

## Intake
1. Load `task-dispatch`.
2. File one council ticket with the owner's words quoted.
3. File each lane as a child ticket of it through `task-dispatch`, with the sections strict intake asks for.
4. A lane's task id is its ticket id with dots as dashes; `bin/jg-brief.sh` refuses any other.

## Lanes
- Three variant Recons, one angle each. Default angles: the smallest change; the strongest guarantees; outside prior art first. The owner may name others.
- Start all variants with one command, never one by one: `bin/jg-war-room.sh start <council> --project <p> --angles <a,b,c> --depth deep --harness <h> --model <m> --effort <e>`. It files each variant's child ticket (found again by its title, never filed twice), writes its brief and starts every lane without a live task record at once. Exit 0 means every lane is live; a line that says `not started` names the refusal.
- One critic ticket for each variant, then the synthesis Recon and its critic, then the dry run of order 1.
- Load `quota-array-dispatch` for the profile. Use the strongest profile at xhigh for Recons, critics and the synthesis. Mix families only when the owner asks: then one variant on each verified family with quota.
- Run the dry run on the first order's model.
- Tell the owner the lane count and that the strong lanes cost most.

## Each Recon's spec
- The angle.
- "Run `bin/jg-recon-handoff.sh draft <task>` before your done line and `bin/jg-recon-handoff.sh revise <task>` after you fix a round's gaps."
- "You may run `bin/jg-captain-hold.sh hold` and `complete` for this task's own decisions (captain-hold-lifecycle). Write no other backlog item."
- "Round 3 is the last round that may report gaps. A gap you cannot close in one revision moves to section 7 or 10 with its reason, and the critic closes it as carried."

## Critics
1. `bin/jg-war-room.sh next <council>` does this step: when a lane's draft is recorded, it files, briefs and starts the lane's critic and runs `bin/jg-recon-handoff.sh assign <task> --critic <critic task>`. That record, not a name, links the draft to its critic.
2. The recon handoff starts `next` by itself after each `draft`, `revise` and `verdict` of a council lane (`JG_WAR_ROOM_NEXT=0` turns that off; run `next` by hand then).
3. The critic's spec: read with the deep-recon rubric, and end each round with `bin/jg-recon-handoff.sh verdict <task> --critic <critic task> --hash <sha256 of report.md> --gaps <k>`.
4. The verdict writes `critic.md`. For council lanes this replaces deep-recon's step "Overwatch installs it".
5. Where the handoff does not send a round to the critic by itself, send one steer per round naming the draft's hash.

## Synthesis
1. `next` does this step: when every variant passes `bin/jg-recon-gate.sh <task>`, it starts the synthesis with the three report paths.
2. Its spec requires `strike-recon` at stage 1 and `op-order` with `orders/plan.json` at the end.

## Dry run
`next` dispatches the dry run of order 1 on a scratch copy when the synthesis passes. The synthesis fixes the order and records the measured budget.

## Report to the owner
When the dry run is done and `bin/jg-swarm-plan-check.sh` passes the plan, `next` holds the council for the owner's plan approval and prints `owner approval asked`.
Send one message with:
- the answer;
- the slice and wave counts;
- each owner-only decision as a board card.

After the owner's yes, run `bin/jg-war-room.sh approve <council> --words "<the owner's words>"`. It records the approval and starts `/blitz` on the plan once.
