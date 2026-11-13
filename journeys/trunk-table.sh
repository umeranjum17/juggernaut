#!/usr/bin/env bash
# done-done journey: the trunk line of a project has 4 states. The real jg-machine.sh lints the trunk table and lists its moves; the behavior
# test (tests/jg-machine-trunk.test.sh) reads a fixture record in every state through the real observer and checks that a legal move adds no
# line to the shadow log.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
jm="$root/bin/jg-machine.sh"
rc=0
{
  bash "$jm" check trunk || rc=1
  bash "$jm" events trunk || rc=1
  bash "$root/tests/jg-machine-trunk.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped trunk table and generated fixture records, with a real git clone for the red check",
 "steps": ["lint the trunk table and its enum", "list its moves", "read a fixture record in each of the four states through the real observer", "report one legal and one illegal move to the shadow log"],
 "result": "the table lints with 4 states and 6 moves, each fixture prints the right word, a legal move adds no shadow line and an illegal one adds one"}
JSON
exit "$rc"
