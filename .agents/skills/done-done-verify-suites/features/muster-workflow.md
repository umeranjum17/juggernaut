# An approved Muster workflow starts Blitz

Run `done-done run muster-workflow` to set each workflow on a ticket, answer its board questions, and confirm that Blitz arms its first slices with the signed pack.
The fixture covers discovery before Muster, light Muster by itself, Recon before Muster, and two Muster invocations in parallel.
In the light run a document is sent back with `jg muster revise` while the pack is ready: the next draft round gets the note, the approved document is its second version, and an approved document reopens with a reason.
[`tests/jg-muster-drafts.test.sh`](../../../../tests/jg-muster-drafts.test.sh) pulls drafts at three stages, sends two documents back, and checks the diffs and the documents flagged to re-check.

Sources: `core/workflows/`, `defaults/workflows`, `defaults/workflow-routes`, `core/muster/approval.py`, `bin/jg-war-room.sh`, `bin/jg-muster-objectives.sh`, `bin/jg-muster-drafts.sh`, `core/muster/drafts.py`, `bin/jg-board-answers.sh`, `bin/jg-swarm.sh`, `bin/jg-swarm-plan-check.sh`, and `tests/jg-workflow-muster.test.sh`.
