#!/usr/bin/env bash
# The one install command on a clean HOME: every part up, a second run identical, a broken part stopping the run.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${DONE_DONE_RUN_ID:-run}.log
bash "$root/tests/jg-stack.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
exit "$rc"
