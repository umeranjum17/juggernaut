#!/usr/bin/env bash
# done-done journey: the Squad Lead home, supervisor session and presence tables. The real jg-machine.sh lints each table and lists its
# moves; the behavior test (tests/jg-machine-observers16.test.sh) calls the real command on a fixture record in every state.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
jm="$root/bin/jg-machine.sh"
rc=0
{
  for m in squad-lead supervision presence; do bash "$jm" check "$m" || rc=1; bash "$jm" events "$m" || rc=1; done
  bash "$root/tests/jg-machine-observers16.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped squad-lead, supervision and presence tables and fixture homes",
 "steps": ["lint the three tables", "list their moves", "read a Squad Lead fixture in each of six states", "read a supervisor fixture in each of five states", "read a presence fixture in each of four states", "check the observers write nothing"],
 "result": "the tables lint with 6, 5 and 4 states, and each observer prints the right word for every state"}
JSON
exit "$rc"
