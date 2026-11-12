#!/usr/bin/env bash
# done-done journey: a ticket's trail gets its start, ready, receipt and evidence from the supervising side. The behavior test
# (tests/jg-trace-writers.test.sh) runs the verb jg-backlog.sh trace record, the delivery tick's ready step and the merge's receipt step
# on a real Beads store.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
: "${JG_BEADS_TEST_BD:=$(command -v bd)}" "${JG_BEADS_TEST_DOLT:=$(command -v dolt)}"
export JG_BEADS_TEST_BD JG_BEADS_TEST_DOLT
rc=0
bash "$root/tests/jg-trace-writers.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a new Beads store with fixture rows, written and read through jg-backlog.sh",
 "steps": ["record a moment by task id and by ticket id", "record the same moment twice and a moment moved back", "grow the evidence list", "write done, working, done into a lane's status file and run the ready step each time", "run the merge's post-merge step with a PASS receipt"],
 "result": "the event is recorded before the time on the row, a repeat adds nothing, a lane reads ready, not ready, ready with a resume between, and the receipt is a used event with its verdict"}
JSON
exit "$rc"
