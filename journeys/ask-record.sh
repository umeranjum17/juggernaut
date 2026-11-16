#!/usr/bin/env bash
# done-done journey: the ask measurement record. The real bin/jg-ask-record.sh joins a fixture home's ticket moments, sealed run records,
# trunk records and per-home install rows into one record (tests/jg-ask-record.test.sh drives it and saves the record it printed).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
echo "journey run $(git -C "$root" rev-parse HEAD) ${RUN_ID:-run}" > "$out"
bash "$root/tests/jg-ask-record.test.sh" >> "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the real jg-ask-record.sh command in a fixture home with ticket moments, a sealed run, trunk records, install rows and a worker transcript",
 "steps": ["show the ask's record joined from the records", "show the candidate's own proof and minutes", "write and bind a behaviour observation per home", "undo the live moment with a pin-back", "count the worker's model turns", "refuse an ask with no moments"],
 "result": "every field of the record is filled from the records, and a field no record shows is named in missing"}
JSON
exit "$rc"
