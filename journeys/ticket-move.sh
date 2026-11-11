#!/usr/bin/env bash
# done-done journey: the one move command. The real bin/jg-move.sh, over a test home, refuses an illegal ticket move with exit 1
# and writes nothing, and appends one line for a legal move; tests/jg-move.test.sh drives it.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-move.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a test home holding a copy of the ticket tables and a ticket in the building stage",
 "steps": ["run jg-move with an event the stage does not have", "run jg-move with claim-done", "run jg-move on a ticket in no stage with start, then file"],
 "result": "the illegal move exits 1, names the legal events and writes no line; each legal move appends exactly one line"}
JSON
exit "$rc"
