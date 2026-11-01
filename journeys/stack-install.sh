#!/usr/bin/env bash
# The one install command on a clean HOME: every part up, a second run identical, a broken part stopping the run.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${DONE_DONE_RUN_ID:-run}.log
bash "$root/tests/jg-stack.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a clean throwaway HOME with a fresh clone and none of the four tools installed",
 "steps": ["run bin/jg-stack.sh up", "read one line per part: installed, enabled, running pid, listening (wake-engine and router: consuming <stream>/<consumer>)", "run bin/jg-stack.sh up again", "break ntfy and run it a third time"],
 "result": "every part is up with a pid and listener, the second run is identical, and the broken part stops the run with one STACK_FAILED line"}
JSON
exit "$rc"
