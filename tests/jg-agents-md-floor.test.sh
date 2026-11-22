#!/usr/bin/env bash
# tests/jg-agents-md-floor.test.sh - the always-loaded AGENTS.md keeps its safety
# core inline, and every rule moved out of it to cut the per-request instruction
# floor lives, once, in the skill this ledger names, behind a Load trigger that
# AGENTS.md still carries.
#
# Ledger row: <old AGENTS.md section>|<where the rule lives now>|<its opening words>.
# A rule that moved is absent from AGENTS.md; the one row naming AGENTS.md is a
# duplicate that was dropped because the same line stays inline there.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

agents=$ROOT/AGENTS.md

# AGENTS.md is generated from docs/roles/rules.tsv (tests/role-pack-budget.test.sh --write): the all pack, then Main's.
for heading in '## 1. Identity and prime directives' '## 7. Task lifecycle' '## 9. Escalation and captain etiquette' \
  '## 11. Briefs, self-update, skills and Relay'; do
  grep -qxF -- "$heading" "$agents" || fail "AGENTS.md lost its inline '$heading'"
done
for rule in 'Never write to a project.' "Never merge a PR without the captain's explicit word." \
  'Never tear down unlanded work.' 'Operators never address the captain.' 'Report outcomes faithfully.'; do
  grep -qF -- "**${rule%.}" "$agents" || fail "AGENTS.md lost hard rule '$rule'"
done

# One owner for each of the nine pipeline steps: the contract and both supervision skills say it, and the old
# no-mistakes-owns-everything lines are gone.
! grep -qF -- 'no-mistakes alone owns' "$agents" || fail "AGENTS.md still gives no-mistakes the nine steps"
! grep -qF -- 'escalate whether to use no-mistakes' "$agents" || fail "AGENTS.md still offers a mode to choose for rigor"
grep -qF -- 'done-done owns review, fixes, tests and documentation' "$agents" \
  || fail "AGENTS.md does not give review, fixes, tests and documentation to done-done"
grep -qF -- "wait \`lead\`, reason \`review\`" "$agents" || fail "AGENTS.md lost the review wait"

# Owner rule 10445fb9 (captain, 2026-11-11: skip some verification, bare minimum, until the fleet is stable; full
# checks return only on his word) is enforced by the precedence section and the intake line that point to it. Removing
# any of these sentences stops a current explicit captain instruction from lowering rigor at a validation or landing
# choice, or lets one request turn into standing authority.
precedence=$(awk '/^## 11\. /{f=1;next} /^## /{f=0} f' "$agents")
# shellcheck disable=SC2016 # the backticks are literal Markdown
for line in 'A current, explicit, concrete captain instruction' \
  'overrides a conflicting standing rule above' \
  'never infer, broaden or carry it to another case' \
  'Standing `yolo` is not such an instruction'; do
  printf '%s\n' "$precedence" | grep -qF -- "$line" || fail "precedence section lost '$line'"
done
grep -qF -- 'a current explicit captain instruction, else the project'"'"'s registry entry' "$agents" \
  || fail "AGENTS.md intake lost the rule that a current explicit captain instruction wins over the standing posture"
# shellcheck disable=SC2016 # the backticks are literal Markdown
grep -qF -- 'only a project'"'"'s approved `yolo` posture relaxes this' "$agents" \
  || fail "AGENTS.md hard rule 2 lost its only standing relaxation"

rows=0
while IFS='|' read -r section dest anchor; do
  [ -n "$section" ] || continue
  rows=$((rows + 1))
  if [ "$dest" = AGENTS.md ]; then
    grep -qF -- "$anchor" "$agents" || fail "section $section rule '$anchor' should stay inline in AGENTS.md"
    continue
  fi
  [ -f "$ROOT/$dest" ] || fail "section $section rule '$anchor' points at missing $dest"
  n=$(grep -cF -- "$anchor" "$ROOT/$dest")
  [ "$n" = 1 ] || fail "section $section rule '$anchor' appears $n times in $dest, want 1"
  ! grep -qF -- "$anchor" "$agents" || fail "section $section rule '$anchor' is still restated in AGENTS.md"
  skill=${dest#.agents/skills/}; skill=${skill%%/*}
  grep -qF -- "Load \`$skill\`" "$agents" || fail "AGENTS.md has no Load trigger for $skill, where '$anchor' moved"
done <<'LEDGER'
2|.agents/skills/fleet-records/SKILL.md|`docs/configuration.md` is the single owner of the top-level operational-home
2|.agents/skills/fleet-records/SKILL.md|`JG_HOME` selects an instance's private `data/`, `state/`, `config/`, and
2|.agents/skills/fleet-records/SKILL.md|Each Squad Lead has a persistent isolated `JG_HOME`, including
2|.agents/skills/fleet-records/SKILL.md|Tracked files hold shared instructions and tooling; `data/` holds
4|.agents/skills/task-dispatch/SKILL.md|`docs/configuration.md` owns dispatch-profile and runtime-backend schemas, `bin/jg-harness.sh` owns static
4|.agents/skills/task-dispatch/SKILL.md|When dispatch profiles exist, consult them at every operator
4|.agents/skills/task-dispatch/SKILL.md|Routing precedence is an explicit per-task captain override, then
4|.agents/skills/quota-array-dispatch/SKILL.md|Overwatch alone resolves a matched profile array: begin with
4|.agents/skills/quota-array-dispatch/SKILL.md|Account for every candidate with the catalog evidence, provider
4|.agents/skills/quota-array-dispatch/SKILL.md|Establish model support and provider family from that harness's
4|.agents/skills/quota-array-dispatch/SKILL.md|Missing model-level quota, a missing authentication source, unmeasurable headroom,
4|.agents/skills/quota-array-dispatch/SKILL.md|Only concrete contradictory evidence blocks a candidate, such as
4|.agents/skills/quota-array-dispatch/SKILL.md|Preserve malformed profile configuration as an actionable error rather
4|.agents/skills/quota-array-dispatch/SKILL.md|When every candidate is tight, preserve the captain's strongest-reasoning
4|.agents/skills/quota-array-dispatch/SKILL.md|Break genuine evidence ties without array-order or harness bias.
4|.agents/skills/quota-array-dispatch/SKILL.md|`quota-axi` owns how model or product windows relate to
4|.agents/skills/task-dispatch/SKILL.md|Run `jg crew dispatch-resolve` directly on the written brief in the
4|.agents/skills/task-dispatch/SKILL.md|The generic effort fallback and its precedence are owned
4|.agents/skills/task-dispatch/SKILL.md|Do not add model-specific versions of that policy.
4|.agents/skills/task-dispatch/SKILL.md|`squad-lead-provisioning` owns Squad Lead harness pins and inherited local
4|.agents/skills/task-dispatch/SKILL.md|Dispatch only on a backend that `jg-spawn` validates as
6|.agents/skills/fleet-records/SKILL.md|Its scope field drives routing and its project list
6|.agents/skills/fleet-records/SKILL.md|Routed backlog items count as routed work: when a
6|.agents/skills/fleet-records/SKILL.md|Route durable knowledge to its most specific owner:
6|.agents/skills/fleet-records/SKILL.md|A home may declare authoritative external memory tiers in
6|.agents/skills/fleet-records/SKILL.md|When a worker's harness cannot reach a declared tier,
6|.agents/skills/fleet-records/SKILL.md|A standing owner correction becomes a rule in `data/owner-rules.md`
6|.agents/skills/fleet-records/SKILL.md|Home-domain captain preferences and working style belong in `data/captain.md`
6|.agents/skills/fleet-records/SKILL.md|Captain preferences shared across Squad Lead domains belong in
6|.agents/skills/fleet-records/SKILL.md|Fleet-local operational facts no declared tier owns belong in
6|.agents/skills/fleet-records/SKILL.md|Task-scoped notes belong with the backlog item, and investigation
6|.agents/skills/fleet-records/SKILL.md|Knowledge useful to almost every contributor to one project
6|.agents/skills/fleet-records/SKILL.md|Knowledge general to every Juggernaut user belongs in this
7|.agents/skills/task-dispatch/SKILL.md|Resolve the project independently for every request.
7|.agents/skills/task-dispatch/SKILL.md|An explicit project wins, a clear follow-up inherits its
7|.agents/skills/task-dispatch/SKILL.md|Proceed on one confident match while naming the project
7|.agents/skills/task-dispatch/SKILL.md|Route by the nature of the work against each
7|AGENTS.md|Keep `local-only` work in the main home.
7|.agents/skills/task-dispatch/SKILL.md|Send in-scope work to the fitting Squad Lead unless
7|.agents/skills/task-dispatch/SKILL.md|If no Squad Lead scope fits, use the main
7|.agents/skills/task-dispatch/SKILL.md|For one-off or infrequent operational work, start with the
7|.agents/skills/task-dispatch/SKILL.md|Do not build wrappers, control planes, policy layers, custom
7|.agents/skills/task-dispatch/SKILL.md|Before commissioning an investigation, consult existing reports and established
7|.agents/skills/task-dispatch/SKILL.md|Classify the deliverable:
7|.agents/skills/task-dispatch/SKILL.md|Ship** is the default and produces a project change
7|.agents/skills/task-dispatch/SKILL.md|Recon** produces knowledge in `data/<id>/report.md`, never a PR, and
7|.agents/skills/task-dispatch/SKILL.md|If established evidence already answers an informational question, relay
7|.agents/skills/task-dispatch/SKILL.md|Never both present a likely-enough solution and launch a
7|.agents/skills/task-dispatch/SKILL.md|Pass the mode explicitly to the brief, and pass
7|.agents/skills/task-dispatch/SKILL.md|Resolve the project's registered ship-branch prefix the same way,
7|.agents/skills/task-dispatch/SKILL.md|When the work must start from and target a
7|.agents/skills/task-dispatch/SKILL.md|For a ship task whose project is this Juggernaut
7|.agents/skills/task-dispatch/SKILL.md|Record the resulting mode, `yolo` merge posture, and the
7|.agents/skills/task-dispatch/SKILL.md|Treat file or subsystem overlap as a risk signal
7|.agents/skills/task-dispatch/SKILL.md|A project's declared machine capacity (`config/project-capacity`) and the machine's load
7|.agents/skills/task-dispatch/SKILL.md|Serialize only for a true semantic dependency, shared mutable
7|.agents/skills/task-dispatch/SKILL.md|Write the task-specific brief under the brief rules below
7|.agents/skills/task-dispatch/SKILL.md|When the configured the backlog backlog gate applies, the spawn
7|.agents/skills/task-dispatch/SKILL.md|After spawning, confirm the worker is processing the brief
7|.agents/skills/task-dispatch/SKILL.md|A persistent Squad Lead is recorded in the Squad
7|.agents/skills/task-dispatch/SKILL.md|Steer a worker with ordinary text through fail-closed `jg-send`:
7|.agents/skills/task-dispatch/SKILL.md|A remote Squad Lead steer rides the same durable-inbox
7|.agents/skills/task-dispatch/SKILL.md|When a steer answers an open keyed decision or
7|.agents/skills/task-dispatch/SKILL.md|For the parent-owned correlation, recovery, and escalation contract on
7|.agents/skills/task-dispatch/SKILL.md|When the captain adds or changes an ask mid-task,
10|.agents/skills/fleet-records/SKILL.md|the durable queue; `jg ticket backlog markdown` renders them
10|.agents/skills/fleet-records/SKILL.md|It tracks work items only, never agents; persistent Squad
10|.agents/skills/fleet-records/SKILL.md|Work routed to a Squad Lead is recorded in
10|.agents/skills/fleet-records/SKILL.md|When a main-side thread such as a pending captain
10|.agents/skills/fleet-records/SKILL.md|When the automatic transition gate applies, dispatch and completion
10|.agents/skills/fleet-records/SKILL.md|`docs/configuration.md` and current `jg ticket backlog help` own the backlog
10|.agents/skills/fleet-records/SKILL.md|`squad-lead-provisioning` and `jg ticket backlog-handoff` own cross-home handoff safety.
10|.agents/skills/fleet-records/SKILL.md|Keep free-form notes free of temporary paths, moving versions,
10|.agents/skills/fleet-records/SKILL.md|Inspect the current task note before replacing its considered
10|.agents/skills/fleet-records/SKILL.md|Verify volatile details against their authoritative config, live system,
10|.agents/skills/fleet-records/SKILL.md|Preserve durable structured identifiers, dependencies, and completion artifact links,
11|.agents/skills/task-dispatch/SKILL.md|`bin/jg-brief.sh` and its help own scaffold syntax, generated variants,
11|.agents/skills/task-dispatch/SKILL.md|Use its scaffold as the contract, then fill `##
11|.agents/skills/task-dispatch/SKILL.md|Fill `## Juggernaut spec` (`{JUGGERNAUT_SPEC}`) with only the build
11|.agents/skills/task-dispatch/SKILL.md|`bin/jg-dod-lib.sh` owns intent authoring without added speaker labels or
11|.agents/skills/task-dispatch/SKILL.md|Keep additions task-specific rather than repeating lifecycle instructions, and
11|.agents/skills/task-dispatch/SKILL.md|Status appends are sparse supervisor-actionable events, not routine progress;
LEDGER
[ "$rows" -gt 0 ] || fail "the moved-rule ledger is empty"
pass "AGENTS.md safety core inline; $rows moved rules each live once behind a Load trigger"
