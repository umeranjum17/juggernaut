#!/usr/bin/env bash
# done-done journey: the owner's bypass of proving has one record and one command. The real jg-machine.sh lints the bypass table, and
# the behavior test (tests/jg-proof-bypass.test.sh) runs the real command and the real delivery tick in a fixture home.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
jm="$root/bin/jg-machine.sh"
rc=0
{
  bash "$jm" check bypass || rc=1
  bash "$jm" events bypass || rc=1
  bash "$root/tests/jg-proof-bypass.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped bypass table and the real jg-proof-bypass.sh command and delivery tick in a fixture home",
 "steps": ["lint the bypass table", "refuse a worker, a missing word id, a bad scope and a past end time", "grant a project bypass with the default end", "list and find it", "end a ticket bypass at release by the tick", "read an expired bypass as ended and prove the next done line"],
 "result": "the table lints with 2 states and 4 moves, every refusal writes nothing, and an expired bypass reads ended"}
JSON
exit "$rc"
