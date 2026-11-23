# Muster, Recon and War Room hand off to Blitz

Run `done-done run -- bash journeys/muster-workflow.sh` from the repository root.
The [workflow integration journey](../../../../tests/jg-workflow-muster.test.sh) drives three orderings and parallel Muster steps on an isolated help desk project using real board, pack and Blitz commands.
Fixture workers produce the reports, drafts and orders.
One draft is sent back with a note before approval, and the approved pack is then reopened.
The run records the approval and launch output in `muster-workflow.log`, regression results in `workflow-regressions.log`, and lint in `workflow-lint.log`.
