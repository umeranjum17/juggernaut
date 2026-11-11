#!/usr/bin/env bash
# done-done journey: the table lint holds the rule of section 6.12. The real jg-machine.sh lints every machine table of this repository,
# then refuses a fixture machine for each defect of the rule and names the state; the behavior test (tests/jg-machine-lint.test.sh) runs after.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
jm="$root/bin/jg-machine.sh"; rc=0
{
  for f in "$root"/core/machines/tables/*.tsv; do bash "$jm" check "$(basename "$f" .tsv)" || rc=1; done
  bash "$root/tests/jg-machine-lint.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped machine tables and generated fixture tables, each with one defect of the rule of section 6.12",
 "steps": ["lint every shipped machine table", "lint five fixture tables (a waiting state with no timeout, an unreachable state, two first events, a final state with a way out, an event with two targets) and require a refusal that names the state", "lint the other defects of the rule"],
 "result": "every shipped table passes and each fixture is refused with the state or event named"}
JSON
exit "$rc"
