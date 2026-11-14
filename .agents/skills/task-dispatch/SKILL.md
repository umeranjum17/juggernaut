---
name: task-dispatch
description: >-
  Agent-only intake and dispatch procedure kept out of the always-loaded AGENTS.md.
  Load at every intake of project work and before choosing a dispatch profile, effort, or backend, writing a brief, spawning, promoting, or steering a worker.
user-invocable: false
metadata:
  internal: true
---

# task-dispatch

This skill owns the intake, routing, dispatch, steering, and brief-filling procedure that `AGENTS.md` sections 4, 7, and 11 point to.
The safety rules, merge authority, and load triggers stay in `AGENTS.md`; nothing here relaxes them.

## Project resolution and routing

Resolve the project independently for every request.
An explicit project wins, a clear follow-up inherits its referent, and otherwise match the request against the registry, work under way, and project code or README.
Proceed on one confident match while naming the project in plain language; ask one concise question when multiple or no projects plausibly match.

Route by the nature of the work against each registered Squad Lead scope, not by a non-exclusive clone list.
Send in-scope work to the fitting Squad Lead unless it is blocked or the captain explicitly redirects it; do not read the Squad Lead's chat because marked routed replies return through its status or referenced document.
If no Squad Lead scope fits, use the main home or discuss creating an appropriate persistent Squad Lead.
For one-off or infrequent operational work, start with the simplest direct end-to-end path.
Do not build wrappers, control planes, policy layers, custom verifiers, or automation unless the direct path exposes a concrete blocker or repeated need that justifies the added machinery.

## Ship or Recon

Before commissioning an investigation, consult existing reports and established evidence.
Classify the deliverable:

- **Ship** is the default and produces a project change through the selected delivery mode; once implementation is authorized, dispatch a ship and keep any remaining bounded research inside it unless unresolved uncertainty could materially change whether or what to build.
- **Recon** produces knowledge in `data/<id>/report.md`, never a PR, and is appropriate for investigation, diagnosis, planning, reproduction, or audit work when the captain explicitly requests a separate knowledge or design deliverable or unresolved uncertainty could materially change whether or what to build.

- If established evidence already answers an informational question, relay it without a design-only Recon; when implementation intent is unclear, answer and ask one concise implementation question when useful rather than dispatching speculative design work.
- Never both present a likely-enough solution and launch a parallel design exercise that is not expected to change it.

### Recon depth

Pick the depth of every Recon at intake and pass it to the scaffold as `--depth quick|standard|deep`; `bin/jg-recon-depth.sh "<the ask>"` maps the ask's words to a level, and a level the captain names always wins.
- **deep** for "in depth", "discovery", "deep", "research properly", "detailed report", or a plan with slices.
- **quick** only for one fact.
- **standard** for everything else; it is the default.

A deep Recon needs one separate critic worker after the researcher's draft, never a fan-out: when the researcher reports `done` with its draft ready for the critic (the ticket is in the proving step `critic`), spawn one critic Recon with the task id `<id>-critic` on a fresh isolated copy with that draft, install the critic's output as the researcher's `data/<id>/critic.md`, and steer that same critic for each further round.
Each later draft is a new `done` line of the researcher; steer the same critic to it.
`.agents/skills/deep-recon/SKILL.md` owns the stages, budgets and critic rubric, and `bin/jg-recon-gate.sh` refuses `done` for a standard or deep Recon that does not meet them.

## Delivery mode, branch, and consent flags

For a registered `local-trunk` project, keep `local-trunk` as the task mode through landing and cleanup (`docs/trunk-flow.md`); never translate it to `local-only`.
Pass the mode explicitly to the brief, and pass both values explicitly to the spawn and any Recon promotion; each command refuses to guess the values it consumes.
Resolve the project's registered ship-branch prefix the same way, via `bin/jg-project-mode.sh --branch-prefix --kind <feature|bug|chore> <project>`, and pass it explicitly to the brief, ship spawn, and Recon promotion as `--branch-prefix`; a registered prefix wins, otherwise the kind of the backlog item names the branch (`feature/`, `fix/`, `chore/`), and with no kind it stays `fm/`.
When the work must start from and target a branch other than the project's default, such as a named feature or release branch, pass it to the ship or Recon brief and spawn as `--base-branch <branch>`; any promotion reads it from task meta.
For a ship task whose project is this Juggernaut repository, pass the project directory to the brief as `--project` and record any captain-approved one-task contribution consent as `--upstream-consent <host>/<owner>/<repo>` on the brief, spawn, and promotion; `bin/jg-spawn.sh` refuses a publishing contract this home's role does not authorize.
For a ship task, judge whether it makes a product demo video of an app and pass `--demo-call <yes|no> --demo-reason <text>` to the brief; it takes effect only while `config/takeone-demo` exists (`docs/configuration.md`).
Record the resulting mode, `yolo` merge posture, and the one-line reason for any deviation in the backlog item note.

## Concurrency

Treat file or subsystem overlap as a risk signal rather than an automatic reason to wait, and dispatch isolated work immediately with no concurrency cap when each change can be independently implemented and validated and the selected delivery path can reconcile ordinary rebases or conflicts.
A project's declared machine capacity (`config/project-capacity`) and the machine's load (docs/configuration.md "Host load admission") still bound that dispatch: a spawn beyond either exits 75 without launching, and its item stays queued rather than blocked.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe; same-file editing alone is insufficient, and genuine blockers remain durable.
Dispatch a home's ready routed backlog P0 first, up to project capacity; `fleet-records` owns the routed-backlog record.
A `core/goal-loop` wake names a Goal step: take it like any ready item (ship or fix: spawn a worker and close the step row when the work lands). Stop the Goal with `bin/jg-goal.sh stop` for an owner-only call, a credential, a quota or an outside wait; closing the stop row resumes it.
Write the task-specific brief under the brief rules below and `AGENTS.md` section 11 before spawning.

## Dispatch profiles and backends

`docs/configuration.md` owns dispatch-profile and runtime-backend schemas, `bin/jg-harness.sh` owns static resolution, and `bin/jg-spawn.sh` owns launch flags and fail-closed validation.
When dispatch profiles exist, consult them at every operator or Recon intake and pass the resolved concrete profile required by `jg-spawn`.
Routing precedence is an explicit per-task captain override, then the best-fit configured rule, then the configured default, then the static operator harness.
Run `bin/jg-dispatch-resolve.sh` directly on the written brief in the same turn, with no preflight, and on `clear` pass the `--harness`, `--model`, and `--effort` flags of its `profile:` line to `jg-spawn` unless you state a reason to override, never its trailing `(tier ...)` note, which names the difficulty tier and is not a flag; `ambiguous`, `escalate`, `error`, and off all mean the intake above, unchanged (contract: `docs/configuration.md` "Typed dispatch resolution").
`squad-lead-provisioning` owns Squad Lead harness pins and inherited local material, while `harness-adapters` owns the harness consequences.
Dispatch only on a backend that `jg-spawn` validates as spawn-capable; pass an explicit per-spawn `--backend` only under that exact task's own authority, never as later-task precedent (selection contract: [`docs/configuration.md`](../../../docs/configuration.md) "Runtime backend").

The generic effort fallback and its precedence are owned by `harness-adapters`: explicit captain and standing configured effort win; otherwise use low for well-understood explicit work, xhigh for ambiguous investigation or design, intermediate levels proportionally, and never max without explicit captain preference.
Do not add model-specific versions of that policy.

## Spawn handoff and steering

When the configured the backlog backlog gate applies, the spawn itself moves the work item to In flight and refuses rather than dispatching work this home has no item for, so recording the dispatch is never a separate step to remember; a manual-backend home retains the hand-editing contract in `docs/configuration.md`.
Before writing a brief for a plan's slice, file the slice as a real child: `bin/jg-backlog.sh add --parent <ask> "<title>"` (a second worker's part of a slice: `--parent <slice>`), never a `parent:` body line; use `link` for anything that is not "part of".
After spawning, confirm the worker is processing the brief and handle any trust dialog through `harness-adapters`.
A persistent Squad Lead is recorded in the Squad Lead registry and runtime state, never as a backlog work item.

Steer a worker with ordinary text through fail-closed `jg-send`: the message becomes a durable record in the task's steering inbox (multi-line text is legal, local and remote alike) and the worker's terminal receives only a constant doorbell line, with the watcher re-ringing an unacknowledged local message and escalating a stuck one (`bin/jg-task-inbox-lib.sh`; `bin/jg-send.sh` owns the typed-plane carve-outs).
A remote Squad Lead steer rides the same durable-inbox model through the remote transport; after an unconfirmed delivery, only the exact `JG_PENDING_REPLY_EXISTING_CORR=<id>` resend command printed by `jg-send` is safe because it preserves the request body for remote enqueue deduplication (`bin/jg-send.sh` header).
When a steer answers an open keyed decision or blocker, pass `jg-send`'s `--resolve-key` so the answer itself closes that decision record at answer time, identically for local and remote workers (contract: `bin/jg-send.sh` header).
For the parent-owned correlation, recovery, and escalation contract on marked Squad Lead requests, see `bin/jg-pending-reply-lib.sh`.
When the captain adds or changes an ask mid-task, append the captain's words without added speaker labels or direct address to that brief's `## Captain's intent` and relay those words to the worker; Overwatch build constraints stay in `## Juggernaut spec` or the steer.

## Briefs

A fresh ship or Recon spawn needs `--ticket <ticket-id>` (the brief takes it too); the task id is the ticket id with every dot a dash (`jg-x.1` runs as `jg-x-1`), `bin/jg-backlog.sh task <ticket-id>` prints it, and the spawn refuses a ticket with no row or no readable title (2 to 7 words) and a task id another row answers to. A Squad Lead and a relaunch take no `--ticket`.
`bin/jg-brief.sh` and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of done, and exact safety mechanics.
Use its scaffold as the contract, then fill `## Captain's intent` (`{TASK}`) with the captain's own ask and any boundary the captain stated, plus the context needed to read it, including the substance of any report, decision, or PR the ask refers to; never widen the ask there into a general goal or an enumerated coverage list, because the reviewer treats that subsection as acceptance criteria.
Fill `## Juggernaut spec` (`{JUGGERNAUT_SPEC}`) with only the build instructions that ask requires, naming what stays out of scope when the ask is narrow; a generalization, consistency sweep, or extra hardening the captain did not ask for is follow-up work to note, not scope to add.
`bin/jg-dod-lib.sh` owns intent authoring without added speaker labels or direct address, its provenance markers, what a worker may pass as `--intent`, and the string's self-sufficiency rule.
Keep additions task-specific rather than repeating lifecycle instructions, and alter generated sections only when the task genuinely differs from the standard shape.
Status appends are sparse supervisor-actionable events, not routine progress; `bin/jg-classify-lib.sh` owns keyed open and resolved semantics.
