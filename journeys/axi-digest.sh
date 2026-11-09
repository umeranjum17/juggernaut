#!/usr/bin/env bash
# juggernaut-axi in the session-start digest: a fleet with one finished and one running lane, the real digest, and the finished lane is one juggernaut-axi row; each lane is one row with its last status line.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${DONE_DONE_RUN_ID:-run}.log
JG_SESSION_START_ONLY="test_finished_lanes_fold_into_one_axi_row test_learnings_index_and_body_cap test_digest_stays_under_its_cap_with_300_open_decisions" bash "$root/tests/jg-session-start.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a throwaway fleet home with one finished lane (done status) and one running lane, plus 55 synthetic learnings beyond a 160-byte body cap, and a second home with 320 open decisions and long curated files",
 "steps": ["run the real session-start digest for that home", "look for the finished lane's juggernaut-axi row", "look for its meta block and status tail", "look for the running lane's one row with its last status line", "look for the juggernaut-axi line in the supervision block", "read every complete learning name once in an index with its cap lifted", "read each full body by its indexed sed range", "confirm the default index cap prints the newest headings, the total and the one command that prints all", "confirm the body cap and unchanged local store", "run the digest over a home with 320 open decisions and long curated files and count its bytes", "look for the lock result, the queued wake and its acknowledgement line", "run the full-list command for the open decisions and count them"],
 "result": "the finished lane is one row with no meta block or status tail, the running lane is one row with its last status line, and the supervision block names juggernaut-axi; with the index cap lifted zero learning names are omitted or duplicated, all 55 bodies remain readable, at the default cap the index shows the newest headings with the total and the full-list command, and the body cap holds; with 320 open decisions the digest stays under 40000 bytes, the lock result, queued wake and acknowledgement line print whole, and the full-list command prints all 320"}
JSON
exit "$rc"
