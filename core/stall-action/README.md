# stall-action

A worker or lead whose pane output stays unchanged past its bound is interrupted and re-rung with no model turn.

`stall-action.sh check <jg-home>` is the watcher check.
It prints nothing, so it never wakes anyone.

## What counts as a stall

- A worker: its `state/.hash-<key>` record is older than the bound, and its `state/.count-<key>` poll record is under 10 minutes old.
  The hash file is rewritten only when the pane changes, so the bound counts unchanged output, never elapsed time.
- A lead: the watcher never hashes a lead's pane, so the check reads it with `bin/jg-peek.sh` and keeps its own first-seen time in `data/stall-action/seen/`.
- The bound is 5 minutes for a worker and 10 for a lead.
  `config/stall-bound-workers` and `config/stall-bound-leads` (whole minutes) replace them.
- One hash covers the whole pane tail, so a hung foreground call and a hung background terminal both count.
- An agent whose busy record says idle is exempt only while nothing runs for it.
  If a command that is neither a harness nor a bare shell has run in its worktree for 2 minutes or more (`JG_STALL_ACTION_BG_MIN_AGE`), the idle agent counts as stalled once its pane has stayed unchanged past the bound.
  This is the hung background terminal behind an idle foreground, for example a background checkpoint.
  The probe reads `/proc`; where that is missing the idle record exempts as before.

## What is never touched

- A task with a declared wait (`paused:` or captain-held).
- A task whose latest status event is `done`, `failed`, `needs-decision` or `blocked`.
- A task with a verified exit, or whose busy record says the agent is idle and no background command runs for it.
- A task acted on in the last 30 minutes.

## Action

For each stalled hash the check does two steps, recorded once in `data/stall-action/actions.jsonl`:

- `bin/jg-control.sh <task> interrupt`.
  A failed interrupt is tried once more on a later sweep, then given up for that hash.
- `bin/jg-send.sh <task>` with a short note that the last call was cut off (or, for a hung background command, that it was).
  A lead gets it as a fire-and-forget record.

A new hash is a new stall.

## Wiring

`wiring.sh [--dry-run] <jg-home>` installs the check, writes the shim `state/stall-action.check.sh`, and registers it with `bin/jg-check-register.sh`.
`unwiring.sh [--dry-run] <jg-home>` unregisters it and removes the installed command; that is the rollback.
`bin/jg-host-wiring.sh` runs the wiring for each home.

## Test

`bash stall-action/tests/stall-action.test.sh` runs the whole journey against a fixture home with recorder control and send commands and the real status classifier.
`bash stall-action/run-proof.sh` runs the same journey under `done-done run` and keeps a step record beside the log (screen: none).
