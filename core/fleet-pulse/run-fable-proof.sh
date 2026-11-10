#!/usr/bin/env bash
# Sealed done-done proof for the pulse's Fable wake asking the model guard's allow-tasks (screen: none).
# Fixture journeys run in disposable homes; the live main home is only read (a wiring dry run and the guard's list).
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
main=${JG_MAIN_HOME:-$HOME/juggernaut}
mkdir -p "$evidence"
{
  echo "== fixture homes: old inline block wakes for an allowed task, retarget, allowed quiet, unlisted wakes"
  echo "   (quota-failover tests: one for an allowed task quiet, one for an unlisted task and a route-level one named)"
  bash "$repo/fleet-pulse/tests/fleet-fable.test.sh"
  echo "== fixture home: quota-failover runs a task's one-line test in a folder naming it, a route test in one naming none"
  bash "$repo/quota-failover/tests/quota-failover-e2e.sh"
  echo "== disposable Claude config: guard install, hook refusals, allowed <task-id>, unwiring"
  bash "$repo/claude-model-guard/tests/claude-model-guard.test.sh"
  echo "== live main home $main: what wiring would retarget (dry run, writes nothing)"
  bash "$repo/fleet-pulse/wiring.sh" --dry-run "$main"
  guard=$(bash "$repo/claude-model-guard/wiring.sh" --where)
  echo "== live guard $guard: its allow-tasks"
  if [ -f "${guard%/*}/allow-tasks" ]; then grep -v '^[[:space:]]*$' "${guard%/*}/allow-tasks"; else echo "(no allow-tasks)"; fi
} 2>&1 | tee "$evidence/fleet-fable.txt"
test "${PIPESTATUS[0]}" -eq 0
cat >"$evidence/steps.json" <<'J'
{"target":{"version":"fleet-pulse bin/fleet-fable.sh, wiring.sh, quota-failover and claude-model-guard refuse-model.sh from this checkout"},
 "start":"a disposable main home and lead home whose pulse check carries the old inline Fable block, the guard installed in a disposable Claude config with allow-tasks listing fable-*, and fresh Fable session logs",
 "steps":["run the old check: it wakes for an allowed fable-* task","run wiring.sh: the block now calls fleet-fable.sh","run the check again: allowed tasks are quiet, an unlisted task wakes by name","add quota-failover one-line test sessions: one for an allowed task is quiet, one for an unlisted task wakes by that task, a route-level one wakes by its folder","run quota-failover passes: a task's pinned test runs in a folder naming that task, a route test in one naming none","install, query and unwire the guard in a disposable config","dry-run the wiring against the live main home and print the live allow-tasks"],
 "result":"all three journeys print PASS; the live main home's check is reported as one the wiring would retarget onto fleet-fable.sh"}
J
