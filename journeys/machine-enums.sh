#!/usr/bin/env bash
# done-done journey: each machine has one closed list of states. The real jg-machine.sh loads the 21 enum files of core/machines,
# lints the ticket and delivering tables against theirs, and the whole behavior test (tests/jg-machine-enum.test.sh) runs after it.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
jm="$root/bin/jg-machine.sh"
rc=0
{
  for f in "$root"/core/machines/*.states; do bash "$jm" enum "$(basename "$f" .states)" || rc=1; done
  for m in ticket delivering; do bash "$jm" check "$m" || rc=1; done
  bash "$root/tests/jg-machine-enum.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the 21 shipped enum files and the ticket and delivering tables",
 "steps": ["load each of the 21 enum files", "lint the ticket and delivering tables against their enums", "run the behavior test: a state outside the enum and a list with two initial values are refused by name"],
 "result": "the 21 files load, the two tables name only states of their enums, a stray state and a second initial value fail the lint with the value named"}
JSON
exit "$rc"
