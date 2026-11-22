---
name: war-room
description: Use when the captain invokes /war-room with a hard design or problem - several deep Recons and critics, then one plan in work orders.
user-invocable: true
metadata:
  internal: true
---

# /war-room

## What it does
Runs independent Recons from different angles, then one synthesis that writes the report, the work orders and `orders/plan.json`.
- `/war-room fast <problem>`: three variant Recons at `--depth standard`, started together, with no critic lane (each writes its own critic round); then the deep synthesis with its separate critic, and the dry run.
- `/war-room full <problem>`: three deep variant Recons, a critic for each, the deep synthesis, its critic and the dry run, all at the strongest profile.
- `/war-room lite <problem>`: use `jg plan war-room lite` to start the synthesis Recon, followed by its critic and the dry run.
- `/war-room <problem>` with no word runs `fast` (the owner's pick, 20 Nov).

## Intake
1. Load `task-dispatch`.
2. File one council ticket with the owner's words quoted.
3. File each lane as a child ticket of it through `task-dispatch`, with the sections strict intake asks for.
4. A lane's task id is its ticket id with dots as dashes; `bin/jg-brief.sh` refuses any other.

## Lanes
- Three variant Recons, one angle each. Default angles: the smallest change; the strongest guarantees; outside prior art first. The owner may name others.
- Start all variants with one command, never one by one: `jg plan war-room start <council> --project <p> --angles <a,b,c> --depth deep --harness <h> --model <m> --effort <e>` for `full`; for `fast` use `--depth standard --synthesis-depth deep --no-variant-critics` instead. It files each variant's child ticket (found again by its title, never filed twice), writes its brief and starts every lane without a live task record at once. Exit 0 means every lane is live; a line that says `not started` names the refusal.
- One critic ticket for each variant (not in `fast`), then the synthesis Recon and its critic, then the dry run of order 1. In `fast`, when the handoff does not start `next` by itself after a standard variant's done line, run `jg plan war-room next <council>` by hand.
- Load `quota-array-dispatch` for the profile. Use the strongest profile at xhigh for Recons, critics and the synthesis. Mix families only when the owner asks: then one variant on each verified family with quota.
- Run the dry run on the first order's model.
- Tell the owner the lane count and that the strong lanes cost most.

## Each Recon's spec
- The angle.
- "Run `jg proof recon-handoff draft <task>` before your done line and `jg proof recon-handoff revise <task>` after you fix a round's gaps."
- "You may run `jg hold captain-hold hold` and `complete` for this task's own decisions (captain-hold-lifecycle). Write no other backlog item."
- "Round 3 is the last round that may report gaps. A gap you cannot close in one revision moves to section 7 or 10 with its reason, and the critic closes it as carried."

## Critics
1. `jg plan war-room next <council>` does this step: when a lane's draft is recorded, it files, briefs and starts the lane's critic and runs `jg proof recon-handoff assign <task> --critic <critic task>`. That record, not a name, links the draft to its critic.
2. The recon handoff starts `next` by itself after each `draft`, `revise` and `verdict` of a council lane (`JG_WAR_ROOM_NEXT=0` turns that off; run `next` by hand then).
3. The critic's spec: read with the deep-recon rubric, and end each round with `jg proof recon-handoff verdict <task> --critic <critic task> --hash <sha256 of report.md> --gaps <k>`.
4. The verdict writes `critic.md`. For council lanes this replaces deep-recon's step "Overwatch installs it".
5. Where the handoff does not send a round to the critic by itself, send one steer per round naming the draft's hash.

## Synthesis
1. `next` does this step: when every variant passes `jg proof recon-gate <task>`, it starts the synthesis with the three report paths.
2. Its spec requires `strike-recon` at stage 1 and `op-order` with `orders/plan.json` at the end.

## Dry run
`next` dispatches the dry run of order 1 on a scratch copy when the synthesis passes. The synthesis fixes the order and records the measured budget.

## Report to the owner
When the dry run is done and `jg plan swarm-plan-check` passes the plan, `next` holds the council for the owner's plan approval and prints `owner approval asked`.
Send one message with:
- the answer;
- the slice and wave counts;
- each owner-only decision as a board card.

After the owner's yes, run `jg plan war-room approve <council> --words "<the owner's words>"`. It records the approval and starts `/blitz` on the plan once.
