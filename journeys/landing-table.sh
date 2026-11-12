#!/usr/bin/env bash
# done-done journey: a landing run of a lane has 9 states. The real jg-machine.sh lints the landing table and lists its moves; the behavior
# test (tests/jg-machine-landing.test.sh) reads a fixture record in every state through the real observer, checks that a legal move adds no
# line to the shadow log, and drives a real landing from the host tick.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
jm="$root/bin/jg-machine.sh"
rc=0
{
  bash "$jm" check landing || rc=1
  bash "$jm" events landing || rc=1
  bash "$root/tests/jg-machine-landing.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped landing table and generated fixture records, with real git for the lander",
 "steps": ["lint the landing table and its enum", "list its moves", "read a fixture record in each of the nine states through the real observer", "report six legal moves and two illegal ones to the shadow log", "land a ready lane from one host tick"],
 "result": "the table lints with 9 states and 13 moves, each fixture prints the right word, a legal move adds no shadow line and an illegal one adds one"}
JSON
exit "$rc"
