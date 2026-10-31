#!/usr/bin/env bash
# Sealed done-done proof for the fleet report card (screen: none).
# Runs the fixture table, then builds one real report from a live home's records and
# posts it to a throwaway board with the real sign-off-axi.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
home=${JG_MAIN_HOME:-${JG_HOME:-$HOME/juggernaut}}
mkdir -p "$evidence"
t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
{
  echo "== fixture table"
  bash "$repo/fleet-report/tests/fleet-report.test.sh"
  echo "== live report from $home (24 h)"
  JG_BIN=${JG_BIN:-$home/bin} bash "$repo/fleet-report/bin/fleet-report.sh" "$home" --hours 24
  echo "== post that report to a throwaway board with the real sign-off-axi"
  mkdir -p "$t/home/config" "$t/home/data/metrics" "$t/home/state" "$t/board"
  cp "$home/data/metrics/task-outcomes.tsv" "$t/home/data/metrics/" 2>/dev/null || true
  echo "$t/board/board.json" > "$t/home/config/fleet-board"
  JG_BIN=${JG_BIN:-$home/bin} SIGN_OFF_HOME=$t/so \
    bash "$repo/fleet-report/bin/fleet-report.sh" "$t/home" post --hours 24
} 2>&1 | tee "$evidence/fleet-report.txt"
test "${PIPESTATUS[0]}" -eq 0
cat >"$evidence/steps.json" <<'J'
{"target":{"version":"fleet-report bin/fleet-report.sh and bin/fleet-alerts-ledger.sh from this checkout"},
 "start":"fixture records for the table, and the live home's task outcomes and flow records for the real report",
 "steps":["run the fixture table: merges, PR dedupe, stuck buckets, ready and captain counts, alert stems, false alarm, clear time, post, tick cadence","build one report from the live home's records","post that report to a throwaway board with the real sign-off-axi"],
 "result":"every fixture row prints PASS, the live report prints merges per project and lane counts, and the board lists a raised fleet-report card"}
J
