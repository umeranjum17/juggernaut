#!/usr/bin/env bash
# A hung gate script is stopped: the runner's default per-script bound ends it, kills its children (one in a session of its
# own), removes its temp folder and names it. Driven through the real runner with the shipped default applied (no flag).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${DONE_DONE_RUN_ID:-run}.log
rc=0
(cd "$root" && bash bin/jg-test-run.sh --show-limits && bash bin/jg-test-run.sh tests/jg-test-run.test.sh) > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a fixture test script that sleeps past the bound, with a child in its own session and a temp folder, run by the real runner with no bound flag",
 "steps": ["run the gate over the hung script with script_timeout_seconds=2", "check the script, its children and its temp folder"],
 "result": "the runner prints JG_TEST_TIMEOUT naming the script, exits non-zero, every child process is gone and the script's temp folder is removed"}
JSON
exit "$rc"
