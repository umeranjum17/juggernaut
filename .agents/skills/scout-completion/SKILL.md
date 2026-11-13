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
When you relay a Recon's findings, write the move `bin/jg-move.sh <ticket> relayed`. The lead-sweep cleans a Recon only after that move and 60 quiet minutes in its inbox; a done line, a passed critic or a gone agent never makes it cleanable, and a new message to the Recon restarts the hour.
Before relaying a plan or report, run `bin/jg-loss-claim-check.sh <report>`: a line that says a capability is lost needs a named replacement path and an effort in the same block, or the report goes back.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.
When a Recon's deliverable is a visual artifact the captain will review, publish it as a sign-off board report with `sign-off-axi` and put that sign-off report link in the report; never arm or poll a retired review surface from Juggernaut.
The page must open with the report's Answer, not a finding: the picture heading is the report's first Answer line, and scout teardown refuses a posted page that fails `bin/jg-report-opening-check.sh`; repost the page under the same key to clear it.
When implementation is separately authorized, promote the existing Recon through `bin/jg-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean copy of the task's base (its recorded base branch, else the default branch), carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.
