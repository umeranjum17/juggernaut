#!/usr/bin/env bash
# done-done journey: every local-trunk landing gets one latency row, and a landing over the five-minute target
# raises one alert naming the stage that held it. The real core/trunk-latency/latency.sh replays the records of two
# landings of 9 and 10 Nov (landing rows, proofs, launch logs, done lines, a sealed run) in a fixture home:
#   fric-s14-release-one-url   32 minutes from its done line: one row naming the queue, and one alert.
#   fric-gate-shard-timeout     2 minutes: one row with the host load, and no alert.
# It also proves a third tick writes nothing, the limit is JG_MERGE_LATENCY_LIMIT_MINUTES, a first run counts old
# landings in one line, and the wiring's installed shim runs the check.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
env -u JG_TASK_ID bash "$root/tests/jg-trunk-latency.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a fixture home holding the real landing rows, proof rows, launch logs, done lines and a sealed run of two landings of 9 and 10 Nov, checked by the real core/trunk-latency/latency.sh at the clock of each landing",
 "steps": ["run the check after the 32-minute landing and require one row naming the queue and one alert", "run it after the 2-minute landing and require a row with the host load and no alert", "run it again and require no new row and no line", "raise the limit to 40 and require no alert", "run it once over three old landings and require one count line, with a landing that has no done line kept as a row with an empty ready field", "install the check with its wiring and require the shim to run it"],
 "result": "each local-trunk landing has its minutes from the done line to the landing on record, and only a landing over the target raises one alert naming the stage that held it"}
JSON
exit "$rc"
