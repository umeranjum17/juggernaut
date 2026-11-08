#!/usr/bin/env bash
# Drive real learning reads, competing edits, external backup and isolated restore.
set -eu
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/learning-journey.log
bash "$root/tests/jg-learnings.test.sh" > "$out" 2>&1
cat "$out"
