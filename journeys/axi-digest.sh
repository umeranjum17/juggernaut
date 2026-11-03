#!/usr/bin/env bash
# juggernaut-axi in the session-start digest: a fleet with one finished and one running lane, the real digest, and the finished lane is one juggernaut-axi row.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${DONE_DONE_RUN_ID:-run}.log
JG_SESSION_START_ONLY=test_finished_lanes_fold_into_one_axi_row bash "$root/tests/jg-session-start.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
exit "$rc"
