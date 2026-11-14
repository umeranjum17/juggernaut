#!/usr/bin/env bash
# done-done journey: the fleet status board ends under 10 s with 101 homes by reading one digest per home.
# The behavior tests build the lab homes and drive the real `juggernaut-axi board` and `board.sh --digest`.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
{ bash "$root/tests/jg-fleet-status.test.sh" && bash "$root/tests/jg-fleet-status-scale.test.sh" && bash "$root/tests/jg-fleet-steps.test.sh"; } > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "100 lab leads and Main, each with three alerts, and a digest written in each home",
 "steps": ["write each home's digest with board.sh --digest", "make every observer too slow to answer", "run juggernaut-axi board --json", "age one home's digest", "remove another home's digest"],
 "result": "the board ends under 10 s with all 404 rows, names the late digest, and reads the home with no digest live"}
JSON
exit "$rc"
