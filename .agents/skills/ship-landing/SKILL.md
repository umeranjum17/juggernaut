---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/jg-pr-check.sh` refuses to arm merge monitoring on a draft.
The watcher already ran that ready line through `bin/jg-pr-check.sh --from-status` before the wake: when the task's meta now has that `pr=`, the PR is recorded, its merge poll armed, its ready card posted, and its ticket at review.
Recording that PR also publishes its one-line wait on the PR page, so anyone reading the PR sees what it waits for instead of asking; `bin/jg-pr-wait.sh <url> set <line>` replaces that line and `bin/jg-pr-wait.sh <url> clear` removes it when you send work back.
Otherwise run `bin/jg-pr-check.sh <id> <PR url>` yourself with the URL copied from that ready signal or the resolved checks-green `jg-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
`bin/jg-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/jg-crew-state.sh` reports blocked, `bin/jg-pr-check.sh` refuses to register, and a Squad Lead does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
In no-mistakes mode the earlier `done [at=<epoch>]: {summary}` is the pipeline handoff and is not gated.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
Until the captain answers the auto-merge question, the lead makes the merge call itself within one cycle of the required checks going green, and it never leaves that call unnamed: `bin/jg-pr-state.sh --waiting-for <pr url>` prints exactly one `juggernaut/waiting-for: <what>` line naming the draft, the conflicts, the red or unreported required check, or the merge call, and that line belongs in the captain-facing report while the change is in flight.
The required set a pull request waits on is the fast set in `.github/workflows/ci.yml` - the repo invariants, the sharded changed-file lint, and the changed-file tests - which is why that wait is minutes rather than half an hour; every heavier suite runs post-merge and a red one files a fix-forward item that is never a revert.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when Juggernaut should wake, print nothing otherwise, finish before `JG_CHECK_TIMEOUT`, then bind its current bytes with `bin/jg-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/jg-check-unregister.sh <id>` (or `bin/jg-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

Tear down a ship task only after landing is confirmed.
On a confirmed merge of a ship task, `bin/jg-watch.sh` runs `bin/jg-teardown.sh <id>` itself, without `--force`.
A refusal becomes one `check: cleanup after the merge of <id> was refused: ...` wake, so the work to unblock it lands on you rather than on a memory: settle the gate the refusal names, then tear the task down yourself.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion and retain only the configured recent Done history.
Re-evaluating queued work is not yours to remember: teardown stamps the freed place, and the watcher's ready-work check re-raises the same ready set at once in every home, main included.

A Squad Lead is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main Juggernaut decision, after loading `squad-lead-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
