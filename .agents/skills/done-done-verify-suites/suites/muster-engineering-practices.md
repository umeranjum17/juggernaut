# A Muster plan needs settled engineering practices

Run `done-done run -- bash journeys/muster-engineering-practices.sh` from the repository root.
The journey approves versions of the help desk fixture's standards and runs the real `jg muster verify-plan` on a matching plan each time.
An open Observability row and a missing Security row each refuse verification, and restoring the settled directions lets the plan pass.
The run records the CLI output in `muster-engineering-practices.log` and the drive in `steps.json`.
