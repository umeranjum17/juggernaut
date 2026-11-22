---
name: scout-completion
description: Load when a Recon reports completion, presents a visual artifact for iteration, or is being considered for promotion to implementation.
user-invocable: false
metadata:
  internal: true
---

# Recon outcome and promotion

A completed Recon must leave a self-contained report before its scratch worktree can be discarded; read and relay its findings, record the report as the Done artifact, and re-evaluate the queue.
A report may recommend implementation but does not authorize it.
The delivery tick posts a finished Recon's report on the configured board and records its relay after the post succeeds.
If the relay is still owed, use the manual relay below.
When you relay a Recon's findings, write the move `jg ticket move <ticket> relayed`. Until that move exists the done line still owes its next step: a sweep of its outcome is refused, and after 10 minutes the `done-unhandled` P1 holds your turn end (`bin/jg-facts-lib.sh` `jg_fact_next_step` names the step for a critic and for a draft awaiting a critic too, and for a deep Recon those are the loop's own moves: `core/recon-loop` takes them, and a draft ready and untouched for 10 minutes raises the same P1). The lead-sweep cleans a Recon only after that move and 60 quiet minutes in its inbox; a done line, a passed critic or a gone agent never makes it cleanable, and a new message to the Recon restarts the hour.
A deep Recon's draft-ready line and its critic's round results owe no relay while its critic loop is open (the depth gate reads the step `critic`); relay only after its final done line, because the lead-sweep cleans a relayed Recon's work copy.
Before relaying a plan or report, run `jg report loss-claim-check <report>`: a line that says a capability is lost needs a named replacement path and an effort in the same block, or the report goes back.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.
When a Recon's deliverable is a visual artifact the captain will review, publish it as a sign-off board report with `sign-off-axi` and put that sign-off report link in the report; never arm or poll a retired review surface from Juggernaut.
The page must open with the report's Answer, not a finding: the picture heading is the report's first Answer line, and scout teardown refuses a posted page that fails `jg report report-opening-check`; repost the page under the same key to clear it.
When implementation is separately authorized, promote the existing Recon through `bin/jg-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean copy of the task's base (its recorded base branch, else the default branch), carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.
