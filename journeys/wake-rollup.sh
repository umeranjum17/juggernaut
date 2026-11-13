#!/usr/bin/env bash
# done-done journey: 100 routine events of one Squad Lead home reach Main as one digest line, and a P0 event rings at once.
# Drives core/wake-rollup/tests/wake-rollup.test.sh, which calls the real jg_wake_append and the real rollup check.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/core/wake-rollup/tests/wake-rollup.test.sh" > "$out" 2>&1 || rc=1
printf "run at %s on %s\n" "$(date -u +%FT%T.%NZ)" "$(git -C "$root" rev-parse --short HEAD)" >> "$out"
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a disposable Main home with two Squad Lead homes, a worker and an empty wake queue",
 "steps": ["raise 100 routine status events from one lead home", "check before the 10-minute window closes", "check after it closes", "raise needs-decision, failed and blocked events from the same home", "raise a worker event", "turn the rollup off and raise one more", "write the board file"],
 "result": "the 100 events leave no queue row and one digest line with the counts; the P0 and worker events queue at once; the off switch restores the wake; the board row shows 101 held and 2 digests"}
JSON
exit "$rc"
