#!/usr/bin/env bash
# done-done journey: the host alert. Each producer (the temp-space check, the browser reaper's stop and load, the host memory sampler) calls the real
# jg-alert.sh in a fixture home, and the watcher, the bus and the wake router read the one wake it leaves.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
{
  bash "$root/tests/jg-tmp-reaper.test.sh" || rc=1
  bash "$root/tests/jg-browser-reaper.test.sh" || rc=1
  bash "$root/core/host-memory/tests/jg-host-memory-alert-routing.test.sh" || rc=1
  bash "$root/tests/jg-wake-watcher.test.sh" || rc=1
  bash "$root/tests/jg-wake-router.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped producers of the host alert and the real jg-alert.sh command in fixture homes",
 "steps": ["fill the temp space past its line, once and again, then drop below and cross again", "stop a stale test browser and raise a load episode", "run the host memory sampler in Main, a Squad Lead home and a home with no parent record", "read the one alert-host wake in the watcher, the bus and the wake router"],
 "result": "each host producer raises one alert-host wake per episode through jg-alert.sh, a Squad Lead home only records it, and the watcher and the bus read it"}
JSON
exit "$rc"
