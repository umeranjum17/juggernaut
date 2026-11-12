#!/usr/bin/env bash
# done-done journey: a lane cleanup, or an orphan temp entry, has 5 states. The real jg-machine.sh lints the cleanup table and lists its moves;
# the behavior test (tests/jg-machine-cleanup.test.sh) reads a fixture record in every state through the real observer and checks that a
# legal move adds no line to the shadow log.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
jm="$root/bin/jg-machine.sh"
rc=0
{
  bash "$jm" check cleanup || rc=1
  bash "$jm" events cleanup || rc=1
  bash "$root/tests/jg-machine-cleanup.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped cleanup table and generated fixture records for lanes and temp entries",
 "steps": ["lint the cleanup table and its enum", "list its moves", "read a fixture record in each of the five states through the real observer", "report four legal moves and two illegal ones to the shadow log"],
 "result": "the table lints with 5 states and 7 moves, each fixture prints the right word, a legal move adds no shadow line and an illegal one adds one"}
JSON
exit "$rc"
