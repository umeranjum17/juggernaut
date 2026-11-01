#!/usr/bin/env bash
# Sealed done-done proof for newest-retro discovery (screen: none).
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
mkdir -p "$evidence"
{
  echo "== fixture homes: newest across homes, due/quiet cases, install retarget"
  bash "$repo/fleet-pulse/tests/newest-retro.test.sh"
  echo "== live main home: newest report path"
  bash "$repo/fleet-pulse/bin/newest-retro-report.sh" "${JG_MAIN_HOME:-$HOME/juggernaut}"
} 2>&1 | tee "$evidence/newest-retro.txt"
test "${PIPESTATUS[0]}" -eq 0
cat >"$evidence/steps.json" <<'J'
{"target":{"version":"fleet-pulse bin/newest-retro-report.sh and bin/fleet-retro-due.sh from this checkout"},
 "start":"disposable main and sibling juggernaut homes with planted data/*retro*/report.md files at controlled mtimes",
 "steps":["run the fixture journey: none due, older main plus newer sibling quiet, all old due, wake mark suppresses, install retargets the pulse check","print the newest report path for the live main home"],
 "result":"fixture cases print PASS newest-retro; the live newest path is a data/*retro*/report.md under a known home"}
J
