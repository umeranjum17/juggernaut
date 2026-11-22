#!/usr/bin/env bash
# Sealed done-done proof for the fleet report card (screen: none).
# Runs the fixture table and the registered watcher check, then builds a report from
# fixture records and posts it to a throwaway board with the real sign-off-axi.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
mkdir -p "$evidence"
t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
{
  echo "== fixture table"
  bash "$repo/fleet-report/tests/fleet-report.test.sh"
  echo "== registered fleet-report check under the watcher"
  bash "$repo/../tests/jg-goal-meter.test.sh"
  echo "== post that report to a throwaway board with the real sign-off-axi"
  mkdir -p "$t/home/config" "$t/home/data/metrics" "$t/home/state" "$t/board"
  printf 'home\ttask\tkind\tproject\tmodels\tstarted\tended\toutcome\tpr\nmain\tfixture\tship\tdemo\t-\t1\t%s\tmerged\t-\n' \
    "$(date +%s)" > "$t/home/data/metrics/task-outcomes.tsv"
  echo "$t/board/board.json" > "$t/home/config/fleet-board"
  JG_BIN=$repo/../bin SIGN_OFF_HOME=$t/so \
    bash "$repo/fleet-report/bin/fleet-report.sh" "$t/home" post --hours 24
} 2>&1 | tee "$evidence/fleet-report.txt"
test "${PIPESTATUS[0]}" -eq 0
cat >"$evidence/steps.json" <<'J'
{"target":{"version":"fleet report, goal meter and watcher from this checkout"},
 "start":"isolated homes with fixture task outcomes, alert data and ticket landing events",
 "steps":["run the fleet-report fixture table","run the registered check under the real watcher with its normal deadline","post a report to a throwaway board with the real sign-off-axi"],
 "result":"the fixture table passes, the watcher records the daily goal row with all four landings in one backlog invocation, and the board tool posts the fleet-report card"}
J
