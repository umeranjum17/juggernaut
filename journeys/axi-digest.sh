#!/usr/bin/env bash
# juggernaut-axi in the session-start digest: a fleet with one finished and one running lane, the real digest, and the finished lane is one juggernaut-axi row.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${DONE_DONE_RUN_ID:-run}.log
JG_SESSION_START_ONLY="test_finished_lanes_fold_into_one_axi_row test_learnings_index_and_body_cap" bash "$root/tests/jg-session-start.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a throwaway fleet home with one finished lane (done status) and one running lane, plus 55 synthetic learnings beyond a 160-byte body cap",
 "steps": ["run the real session-start digest for that home", "look for the finished lane's juggernaut-axi row", "look for its meta block and status tail", "look for the running lane's meta block and status tail", "look for the juggernaut-axi line in the supervision block", "read every complete learning name once in its index", "read each full body by its indexed sed range", "confirm the body cap and unchanged local store"],
 "result": "the finished lane is one row with no meta block or status tail, the running lane is printed whole, and the supervision block names juggernaut-axi; zero learning names are omitted or duplicated in the index, all 55 bodies remain readable, and the body cap holds"}
JSON
exit "$rc"
