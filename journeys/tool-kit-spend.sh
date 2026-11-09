#!/usr/bin/env bash
# done-done journey: every tool kit's journey-spend.sh, the journeys that spend model quota or money (core/tool-kits).
# Guard 1 is this script: unless its one argument is `--approved` it prints `skipped: needs spend approval`, exits 0 and calls no
# tool. Guard 2 is the `spends` line of its .done-done.yaml entry: done-done parks the run until it is approved, and the entry's
# own command is the only place that passes `--approved`. It is a flag and not an environment variable because jg-test-run.sh
# maps a journey to its registry entry only when the command starts with `bash journeys/<file>`. journeys/tool-kit.sh proves guard 1.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
KITS=${JG_TOOL_KITS_DIR:-$REPO/core/tool-kits/kits}
log=$OUT/tool-kit-spend.txt status=0 ran=0
: > "$log"
if [ "${1:-}" != --approved ]; then
  echo "skipped: needs spend approval" | tee "$log"; result="skipped: no spend approval, no tool called"
else
  for j in "$KITS"/*/journey-spend.sh; do
    [ -f "$j" ] || continue
    ran=$((ran + 1)); echo "--- $(basename "$(dirname "$j")")" >> "$log"
    bash "$j" >> "$log" 2>&1 || { status=1; echo "FAIL $j" >> "$log"; }
  done
  cat "$log"; result="ran $ran spending kit journeys, status $status"
fi
printf '{"target":{"version":"juggernaut core/tool-kits at this commit"},"start":"a kit folder","steps":["run every kit journey-spend.sh when spend is approved"],"result":"%s"}\n' "$result" > "$OUT/steps.json"
exit "$status"
