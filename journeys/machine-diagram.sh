#!/usr/bin/env bash
# done-done journey: the diagram command of the table engine draws each statechart table with Graphviz in a wide and a narrow layout and the chart check
# runs on each. The behavior test (tests/jg-machine-diagram.test.sh) draws the shipped tables into the run's folder, fails a table whose arrows must cross
# with the two arrows named, fails a state whose timeout names no alert of the alert table, and needs @viz-js/viz (toolchain.versions pins it; JG_VIZ_DIR names it).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ev=${DONE_DONE_EVIDENCE_ROOT:?}
out=$ev/${RUN_ID:-run}.log
rc=0
JG_DIAGRAM_REQUIRE=1 JG_DIAGRAM_OUT=$ev/charts bash "$root/tests/jg-machine-diagram.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$ev/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped statechart tables and generated fixture tables, drawn by the real jg-machine.sh diagram with the pinned WebAssembly Graphviz",
 "steps": ["read the two new columns of a state (emits, alert) and fail a timeout that names no alert of the alert table", "print who is told first, next and by a board card", "print the dot text of the ticket", "run the chart check on SVG fixtures with each of its six faults", "stop with the pinned install line when the renderer is missing", "draw a table whose arrows must cross and read the two arrows named", "draw 11 shipped tables in both layouts and check each"],
 "result": "22 charts pass the check, none crosses, every narrow chart is 450 pt or less, and the fixture that must cross fails with two arrows named"}
JSON
exit "$rc"
