# goal-loop

Works a Goal toward its finish line with no model between steps. A Goal is a Beads epic (`bin/jg-goal.sh declare`)
with five ordered steps: `ship`, `merged`, `released`, `running`, `proven`.

`goal-loop.sh check <home>` is a registered watcher check. Each pass reads every Goal row once (`jg-goal.sh rows`)
and reduces each open Goal to one state: `next` (the first step not closed is open and untaken: wake the lead),
`waiting` (that step is in progress), `stopped` (a row is `on_hold` or `blocked`: the owner's or a blocker's call) or
`finished` (every step closed). Only `next` raises a wake line, naming the Goal and step.

A `next` wake rings once per Goal and step, again after `JG_GOAL_RESURFACE_SECS` (1800) while the step stays open,
and at once if the Goal left `next` and came back. Records sit in `data/jg-goal-loop/`. A home with no
`config/goal-beads-dir` is silent; a store the wrapper refuses raises one wake per reason, with the wrapper's text as
the reason and no fallback to another bd. `goal-loop.sh state <home>` prints the reduction.

Install: `core/goal-loop/wiring.sh <home>` (run by `bin/jg-host-wiring.sh`); `unwiring.sh <home>` removes the shim, the
registration and the installed copy and leaves Goal rows alone. Proof: `bash core/goal-loop/tests/goal-loop.test.sh`.
