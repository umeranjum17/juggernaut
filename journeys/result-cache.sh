#!/usr/bin/env bash
# The result cache: a green script result is reused by a second lane with the same inputs, a changed input runs the script again,
# and a red is never reused. tests/jg-test-run.test.sh drives the real runner over two copies of one repository for it.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${DONE_DONE_RUN_ID:-run}.log
rc=0
(cd "$root" && bash tests/jg-test-run.test.sh) > "$out" 2>&1 || rc=$?
grep -q '^ok - a green result is reused by a second lane' "$out" || { echo "the result cache case did not pass" >> "$out"; rc=1; }
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "two copies of one repository (two lanes) holding a test script that counts its real runs, and an empty result cache folder",
 "steps": ["run the script on the first lane with --cache", "run it on the second lane with --cache", "change a file the script names on the second lane and run it again", "run it with no --cache", "run a script that fails twice with --cache"],
 "result": "the first lane runs the script once; the second lane runs nothing and replays the green output with one JG_TEST_CACHE_HIT line; the changed input and the run with no --cache run the script again; the red script runs again each time and stays red"}
JSON
exit "$rc"
