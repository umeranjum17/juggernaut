---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap or network-checks section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, PRESENTATION_UNAVAILABLE, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, STARTUP_MEMORY_BUDGET, UNIT_HOME, SENTINEL, CREW_DISPATCH invalid, FLEET_SYNC, NETWORK_CHECKS, HOME_SUMMARY, BACKLOG_RECONCILE, SQUAD_LEAD_SYNC, SQUAD_LEAD_LIVENESS, SQUAD_LEAD_HANDOFF, NUDGE_SQUAD_LEADS, or FMX - or reports that an interrupted backlog cleanup may have left an endpoint or local copy, or when a standalone bin/jg-bootstrap.sh or bin/jg-startup-network.sh run prints one of those lines.
  A silent bootstrap section, or any other BOOTSTRAP_INFO fact, means no skill load.
user-invocable: false
metadata:
  internal: true
---

# bootstrap-diagnostics

Handle each printed line as below, before dispatching work that depends on it.
The line formats themselves are owned by `bin/jg-bootstrap.sh`'s header; this playbook owns the response to actionable lines.
The session-start rules in `session-start-recovery` still bind: detect, then consent, then install - never install anything the captain has not approved in this session - and no work is dispatched until the tools it needs are present and GitHub auth is good.
When any diagnostic needs captain attention, report the plain consequence and requested action using `AGENTS.md` section 9's captain-facing translation contract; do not name the diagnostic label unless the captain needs to paste it into a command or issue.

- `MISSING: <tool> (install: <command>)` - list the missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/jg-bootstrap.sh install <approved tools...>`.
  For `treehouse`, this also covers an installed version whose `treehouse get` lacks `--lease`; treat it as an upgrade request.
  For `no-mistakes`, this also covers an installed version older than 1.46.0, because this repo's PR gate requires structured pipeline attestation that older builds do not write.
  For essential axi-family tools - `gh-axi`, `tasks-axi`, `quota-axi` - an installed version below its floor is a plain upgrade request; [`bin/jg-bootstrap.sh`](../../../bin/jg-bootstrap.sh) owns the floor policy, and never argue the floor down to whatever the home happens to have installed.
  For `tasks-axi`, this additionally covers an installed build that fails the separate feature probe (`bin/jg-tasks-axi-lib.sh` owns the definition); `config/backlog-backend=manual` only suppresses the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not this missing-tool report.
  For `quota-axi`, bootstrap requires it because Juggernaut reads its current output directly before resolving every crew-dispatch profile array; without it, report the missing requirement and do not choose around an unexamined candidate.
- `MISSING_MANUAL: <tool> (instructions: <url>)` - tell the captain why the tool is required and give them the printed instructions URL, but do not pass the tool to `bin/jg-bootstrap.sh install`; wait for the captain to complete the manual installation, then rerun session start to confirm the dependency is present.
- `BACKEND_INVALID: <name> (known: <names>)` - the resolved runtime backend has no verified dependency or lifecycle contract, so do not dispatch work until the invalid `JG_BACKEND` or `config/backend` value is corrected to one of the listed backends.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
  This probe now arrives from the deferred network stage, so it is also how an unreachable network shows up: `gh` cannot validate its token offline and reports the same failure. Confirm reachability before asking the captain to re-authenticate a credential that may be fine.
- `NETWORK_CHECKS: <what did not complete>; rerun <command>` - the deferred network stage itself could not finish, so the checks it names are simply unknown, not failed.
  Rerun the printed command; it is idempotent and re-derives every finding.
  A `hit the ...s bound` line means one of those checks is slow or unreachable - most often a remote Squad Lead host - and the stage stopped rather than letting it wedge; a `lock was no longer held` line means the session that asked for the sweeps no longer owns them, so leave them to the session that does.
- `TANGLE: <remediation>` - the primary checkout is stranded on a feature branch instead of its default branch; `AGENTS.md` section 8 explains why this guard exists and what it protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned Juggernaut-initiated git write to the primary, and it is a non-destructive branch switch that strands nothing.
- `BEADS_UNHEALTHY: <reason>` - this home's backlog is in Beads and its store failed `bin/jg-beads.sh check`: a build that is not the pinned one, a store that is not embedded and stealth, the hold rule gone or changed, or telemetry not off.
  Treat backlog reads and writes as unsafe until the printed reason is fixed; a missing or unpinned bd or dolt is a human install, and `bin/jg-beads.sh init` restores a gone rule but never a changed one.
- `STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>` - the visible startup-memory budget is not a safe one-line positive decimal file; do not infer the default or propagate it.
  Correct the local primary file, then rerun session start so the normal convergence path can deliver the validated value to Squad Lead homes.
- `UNIT_HOME: <unit> serves <other home>, not this home` or `UNIT_HOME: <unit> is installed but not running` - one of the machine's four long-running services does not serve Main, so this home gets no alert from it. Main moves them at every session start (`bin/jg-unit-claim.sh claim`), so a line that survives the digest means that move failed: the claim's own failure line above it names the real cause. A Squad Lead home is refused that command on purpose, because Main owns the units there too.
- `SENTINEL: jg-sentinel is not running ... (install: <command>)` - nothing outside the agent runtime recovers supervision and workers after the Herdr server is killed.
  Installing a host service is outward-facing, so ask the captain once and run the printed command only on their word; until then the restart-recovery gap stays open.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; stop profile-based dispatch, report the actionable error, and require correction of the malformed schema, unverified harness name, or invalid harness/effort pair rather than falling back around it or selecting a bad profile.
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`JG_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
  `skipped: registry entry does not resolve to a delivery posture` is the one skip that is not one-off: the clone is left alone on every bootstrap until `data/projects.md` is corrected, so run the printed `bin/jg-project-mode.sh <repo>` to read the refusal and fix the entry.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch an operator or resolve it before it strands work.
- `HOME_SUMMARY: this home has never published state/home-summary.json` or `... has not been republished since <stamp>` - this home's structured summary publication has failed repeatedly, and the line carries the failure count and the newest recorded reason from `state/.home-summary-refresh.log`.
  Publication is deliberately best-effort, so it cannot change another session-start, spawn, teardown, or watcher-poll result, and the watcher runs it detached so a slow attempt cannot delay the liveness beacon.
  Read the named record for the recorded reasons, then reproduce with a direct `bin/jg-home-summary-refresh.sh` (no `--best-effort`, which is what keeps the failure quiet) so the refresh error reaches you.
  A recorded deadline means the complete refresh did not finish inside `JG_HOME_SUMMARY_TIMEOUT`, so inspect lock acquisition and producer completion before validation or publication, and fix the blocked phase rather than raising this load-bearing bound.

- `BOOTSTRAP_INFO: closed the backlog item for <id> after interrupted cleanup; its endpoint or local copy may remain and should be reconciled` - replay closed the item, but the durable transition says physical cleanup was interrupted.
  Verify process reaping, the local-copy return, and endpoint closure, then reconcile any surviving resource.
- `BOOTSTRAP_INFO: kept the captain call for <id> open with its deliverable recorded after interrupted cleanup; its endpoint or local copy may remain and should be reconciled` - replay retained the captain-held item, but physical cleanup was interrupted.
  Verify process reaping, the local-copy return, and endpoint closure without closing or lifting the captain's call, then reconcile any surviving resource.
- `BACKLOG_RECONCILE: <id>: recorded backlog close could not be replayed: <reason>` - this session start found a pending-close record carrying a close or retention transition but could not land it.
  A valid teardown record proves the transition was authorized and recorded, but physical cleanup may be partial: verify process reaping, the local-copy return, and endpoint closure before assuming those resources are gone.
  A validation error means the record cannot be trusted, so do not assume cleanup completed or follow any path or argument stored in it.
  Read the named reason, inspect the marker as inert data when validation failed, fix the record or backlog-file problem, and rerun session start so the valid recorded transition replays.
  Never delete `state/<id>.backlog-close` by hand - that can discard a completion link or captain-call retention the cleanup captured, and the surviving marker prevents the record sweep from starting the item meanwhile.
- `BACKLOG_RECONCILE: <id>: worker record exists but its backlog item could not be read: <reason>` - this home could not determine whether the item matches its worker record.
  Resolve the named backlog read problem and rerun session start; never guess by starting or closing an unreadable item.
- `BACKLOG_RECONCILE: <id>: worker record exists but its backlog item could not be moved to In flight: <reason>` - this home owns a worker whose backlog item is still queued, and the reconciliation could not correct it.
  Until it is corrected, the fleet view reads that worker as work no backlog item owns; resolve the named backlog problem and rerun session start.
- `BACKLOG_RECONCILE: code-root <file> is not this home's <file>; ...` - a tasks-axi write addressed the code root instead of this home, so the queue has already forked and either copy may hold rows the other lacks; [`docs/configuration.md`](../../../docs/configuration.md) ("Backlog backend") owns why.
  Neither copy is a safe winner: union-merge them into this home's file by task id, resolve each conflicting id to its most recent real transition, check this home's archive before treating a missing Done row as lost, and verify the merged id set equals the union of both inputs before installing it.
  Then move the code-root file aside rather than deleting it, tell the captain which rows were recovered, and run every later backlog command through `bin/jg-tasks-axi.sh`; re-linking the code-root copy is never the fix, because the next cwd-relative tasks-axi write replaces the link again.
- `SQUAD_LEAD_SYNC: squad lead <id>: skipped: <reason>` - Squad Lead convergence left a live home on its existing checkout because the home was dirty, diverged, unsafe, on the wrong branch, missing its placement-specific target commit, unreachable, or otherwise not fast-forwardable, or because inherited local-material propagation failed; bootstrap continued, but inspect the reason because the Squad Lead's tracked instructions, inherited settings, or shared captain preferences may be stale after a primary update.
- `SQUAD_LEAD_LIVENESS: squad lead <id>: skipped: <reason>|respawn failed after <cause>: <reason>` - the session-start liveness sweep could not guarantee that the registered Squad Lead is running a real agent process.
  Investigate the reason because that Squad Lead is not guaranteed live.
- `SQUAD_LEAD_HANDOFF: squad lead <id>: pending delivery: <n> item(s)` - queued work has already left the main dispatchable backlog and remains safe in the named remote route's backlog-format outbox because backlog receipt or local outbox cleanup has not completed; [`bin/jg-backlog-handoff.sh`](../../../bin/jg-backlog-handoff.sh) owns the release contract.
  Preserve that outbox and rerun `bin/jg-backlog-handoff.sh --resume-pending` after the route, receipt, or cleanup problem is resolved; never re-add or dispatch the items from the main backlog.
  An unsafe-outbox variant requires path and file-type inspection before any retry.
- `NUDGE_SQUAD_LEADS: squad lead <id>: send failed: <reason>` - Squad Lead convergence changed a running home's loaded instructions or inherited config, but the deterministic `jg-send.sh jg-<id>` re-read nudge failed.
  Inspect the reason, keep the pending marker under `state/.squad-lead-nudge-pending/` intact, and rerun session start after the endpoint or metadata issue is fixed so bootstrap can retry the exact same marked send on the same local or remote route.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local Relay poll artifacts (`docs/configuration.md` "Relay (.env)"); the emitted line still carries Relay's former `X mode` wording.
  Only when a running watcher needs the cadence transition applied immediately, restart the home-scoped watcher through the emitted harness supervision protocol; bootstrap deliberately never restarts the watcher itself.
