# goal-loop

Works a Goal toward its finish line with no model between steps. A Goal is a Beads epic (`bin/jg-goal.sh declare`)
with five ordered steps: `ship`, `merged`, `released`, `running`, `proven`.

`goal-loop.sh check <home>` is a registered watcher check. Each pass reads every Goal row once (`jg-goal.sh rows`)
and reduces each open Goal to one state: `next` (the first step not closed is open and untaken: wake the lead),
`waiting` (that step is in progress), `stopped` (a row is `on_hold` or `blocked`: the owner's or a blocker's call) or
`finished` (every step closed). `next` raises a wake line naming the Goal and step.

A stop is one `on_hold` row under the Goal (`jg-goal.sh stop <goal> --kind <owner-must|credential|quota|external|limit>
--reason <text>`; the store refuses it with no reason). A new stop raises one message with its reason and the action
needed, then the Goal costs no wake. Closing the row (`jg-goal.sh resume <row>`) is the whole resume. A finished Goal
raises one finish message, through `bin/jg-live-claim.sh`, and the check closes its epic. Each message is keyed on the
epic (`goal:<id>:stop:<row>`, `goal:<id>:finish`) before it is printed, so a restart sends none twice. A message whose
write fails rings once for that reason and is tried again on the next pass.

A `next` wake rings once per Goal and step, again after `JG_GOAL_RESURFACE_SECS` (1800) while the step stays open,
and at once if the Goal left `next` and came back. Records sit in `data/jg-goal-loop/`. A home with no
`config/goal-beads-dir` is silent; a store the wrapper refuses raises one wake per reason, with the wrapper's text as
the reason and no fallback to another bd. `goal-loop.sh state <home>` prints the reduction.

Install: `core/goal-loop/wiring.sh <home>` (run by `bin/jg-host-wiring.sh`); `unwiring.sh <home>` removes the shim, the
registration and the installed copy and leaves Goal rows alone. Proof: `bash core/goal-loop/tests/goal-loop.test.sh`.
