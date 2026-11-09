#!/usr/bin/env bash
# Sealed done-done proof for the trunk-era fleet pulse 2h report (screen: none).
# The fixture journey runs the old report before and after wiring.sh; the live part only reads the main home:
# a wiring dry run on its pulse check, and the trunk row and lead asks its records give now.
set -euo pipefail
feature=$(cd "$(dirname "$0")" && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
# The live main home: JG_MAIN_HOME, else the first of ~/juggernaut and ~/firstmate that carries a pulse check.
main=${JG_MAIN_HOME:-}
if [ -z "$main" ]; then
  for h in "$HOME/juggernaut" "$HOME/firstmate"; do [ -f "$h/state/fleet-pulse.check.sh" ] && { main=$h; break; }; done
fi
main=${main:-$HOME/juggernaut}
mkdir -p "$evidence"
{
  echo "== fixture homes: the old 2h report, wiring.sh, the trunk-era report"
  bash "$feature/tests/trunk-pulse.test.sh"
  echo "== live main home $main (read-only)"
  echo "-- wiring dry run on its pulse check"
  bash "$feature/wiring.sh" --dry-run "$main"
  now=$(date +%s)
  echo "-- trunk row (landed live ready_min, last 2 h)"
  bash "$feature/bin/trunk-pulse.sh" "$main" "$((now - 7200))" "$now" || echo "no trunk records: a merged-PR home"
  echo "-- open keyed lead asks to Main past 2 h"
  for meta in "$main"/state/*.meta; do
    grep -qx 'kind=squad_lead' "$meta" 2>/dev/null || continue
    status=${meta%.meta}.status
    printf '%s\t%s\n' "$(basename "${meta%.meta}")" "$(bash "$feature/bin/lead-asks.sh" "$status" "$now")"
  done
} 2>&1 | tee "$evidence/trunk-pulse.txt"
test "${PIPESTATUS[0]}" -eq 0
cat >"$evidence/steps.json" <<'J'
{"target":{"version":"fleet-pulse bin/trunk-pulse.sh, bin/lead-asks.sh and wiring.sh from this checkout"},
 "start":"a disposable main home whose pulse check carries the old 2h report blocks, a trunk home with landing, live and release rows, a merged-PR home behind a stub forge, and a lead channel with open, answered, superseded, keyed-done, unkeyed, captain-hold, continuity and young asks",
 "steps":["run the old report: the trunk home shows landed0 and open unknown and asks count 5","dry-run then run wiring.sh, then rerun it: the report is retargeted once","run the report again: landed, live and rtl from the trunk records, one real ask, the merged-PR home unchanged","check the pin-back, release and no-records rules and the broken-classifier exit","dry-run the wiring on the live main home and print its trunk row and lead asks, read-only"],
 "result":"the fixture journey prints PASS trunk-pulse; the live dry run names the blocks it would retarget and the live rows print"}
J
