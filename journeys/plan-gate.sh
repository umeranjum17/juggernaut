#!/usr/bin/env bash
# done-done journey: the plan gate. The real jg-plan-gate.sh and core/plan-gate/check.sh run from a fixture Main home and a
# fixture Squad Lead home on real Beads stores (tests/jg-plan-gate.test.sh); it skips without JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
JG_BEADS_TEST_BD="${JG_BEADS_TEST_BD:-$(command -v bd)}" JG_BEADS_TEST_DOLT="${JG_BEADS_TEST_DOLT:-$(command -v dolt)}" \
  bash "$root/tests/jg-plan-gate.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a fixture Main home and a fixture Squad Lead home, each with its own Beads store, and the real jg-plan-gate.sh command",
 "steps": ["gate a lead row on a row of Main's store and see it leave ready", "refuse a repeat gate, an unknown home, a row of this home and a missing row", "run one tick of the check with Main's row open and see nothing closed", "close Main's row, run one tick and see the gate closed and the row ready", "gate a row on a tool version and see it open when the tool reports that version", "approve a plan from a lead home and from a file with an unfiled slice, and see both refused with nothing written", "approve the plan from Main and see a dispatch approval record on each slice of the file and none on a later slice"],
 "result": "a gate on another home's row or a tool version closes on one tick and the row is ready, and a plan's approval reaches each of its slices only"}
JSON
exit "$rc"
