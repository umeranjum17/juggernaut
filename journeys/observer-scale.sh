#!/usr/bin/env bash
# done-done journey: every observer ends under 1 s at 10 times today's records, and the move log is read from a cursor.
# The behavior test (tests/jg-observers-scale.test.sh) builds the lab home, times each observer through its real command line and drives
# the real core/machines/observers/cursor.sh.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-observers-scale.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a generated lab home with 10 times today's move log, trunk rows and task records",
 "steps": ["time every observer through its command line", "read a ticket's last move through cursor.sh and compare with a full scan", "append moves and a half-written line, then read again", "read with a named cursor", "replace the log and read again"],
 "result": "each observer ends under 1 s, the cursor matches a full scan, reads only new whole lines and starts again when the log is replaced"}
JSON
exit "$rc"
