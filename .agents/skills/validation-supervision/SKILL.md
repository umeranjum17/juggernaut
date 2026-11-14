---
name: validation-supervision
description: Load when a ship starts or already has an active validation run, including a mid-run requirement change or finding, and before deciding or answering any ask-user finding or review question.
user-invocable: false
metadata:
  internal: true
---

# Validation supervision

Each of the nine steps of a validation run has one owner, in every project.
done-done owns proving: intent, review, test, document and lint, with the fixes of a review finding in its one fix loop.
The delivery style owns delivering: rebase, push, pull request and CI.
A review question the worker cannot settle reaches the lead as the wait `lead`, reason `review`; the worker never answers its own finding, and `ask-user-authority` decides who answers.
The rules below supervise a validation run that is still under way.

The task worker that starts a validation run drives it and owns every gate response through the next gate or outcome.
`bin/jg-dod-lib.sh` owns the worker-side `--intent` contract.
Once validation starts, prefer routing new requirements to follow-up work rather than expanding the current task, unless a new requirement completely invalidates the work being validated; however, the smallest downstream changes needed to keep already accepted product or engineering behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within the current task even when they touch files not named at intake, and corrections required to satisfy already accepted intent are not new requirements.

Only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
That worker cancels the active run through its supported abort command and confirms the run has stopped before changing any code.
The worker must replace the obsolete work from the correct pre-invalidation base rather than building on top of the obsolete head, keeping the obsolete run's own fix commits out of what gets validated and shipped.
Apart from that single abort, do not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.
Once the run has stopped, validate exactly once against that final head so no obsolete or intermediate head is ever treated as authoritative.

An ask-user finding returns as `needs-decision`; Juggernaut loads `ask-user-authority` and either decides or escalates per that skill.
Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command, passing `--resolve-key` so the worker's open decision record closes at answer time.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

Judge validation by the resolved state line from [`bin/jg-crew-state.sh`](../../../bin/jg-crew-state.sh), whose header owns outcome mappings and CI-monitor/daemon exceptions, never by shell liveness, the last status event, or a raw run record.
Workers parked at approval or fix-review must follow the active gate help.
A worker hand-editing, committing, aborting, or restarting during an active validation run duplicates pipeline ownership outside the supersession sequence above; steer it back to the gate response flow.
The worker reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.
