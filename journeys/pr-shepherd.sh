#!/usr/bin/env bash
# done-done journey: a paged pull request becomes a shepherd lane and its next page reaches that lane. The real jg-brief.sh writes the
# lane's one-job brief, the real spawn intake core takes the address, and the installed pager shim pages the live lane and not the lead
# (tests/jg-pr-shepherd.test.sh, with a forge stub and a recording steer command).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-pr-shepherd.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "an open pull request with a red check, a fixture home, and a forge stub",
 "steps": ["scaffold the shepherd brief for the pull request address and see its one job, its forbidden shortcuts and its one merge path", "refuse the flag on a scout, on a bad address and on a mode with no pull request", "take the flag in the spawn intake and refuse it on a scout, a no-pull-request mode and a relaunch", "run the pager with a live shepherd lane and read the page in the lane's steer, with no line for the lead", "run it again an hour later", "finish the lane, fail the send and name another pull request, and see the page go to the lead"],
 "result": "the page for the shepherded pull request reaches the lane and not the lead, and every case with no live lane that takes it still pages the lead"}
JSON
exit "$rc"
