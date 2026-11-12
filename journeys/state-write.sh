#!/usr/bin/env bash
# done-done journey: no state word is written outside its enum. The real jg-machine.sh write refuses `landed` as a ticket
# stage and leaves the file as it was; the real jg-state-lint.sh prints today's count and fails on an added bare state string.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
{ bash "$root/tests/jg-state-write.test.sh" && bash "$root/bin/jg-state-lint.sh" --check; } > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a test home with the ticket tables and enums, a ticket stage file holding building",
 "steps": ["write landed as the ticket stage", "move a ticket whose table lands outside the enum", "run the lint on the repository, then on a fixture that adds a bare state string"],
 "result": "the illegal write is refused with the legal values and the file is unchanged; the lint prints the count and fails on the added string"}
JSON
exit "$rc"
