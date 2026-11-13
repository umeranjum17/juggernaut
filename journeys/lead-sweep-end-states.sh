#!/usr/bin/env bash
# done-done journey: drive the real core/lead-sweep/lead-sweep.sh against a fixture home (resolved lanes landed and not
# landed), through tests/jg-lead-sweep-end-states.test.sh, and write the transcript into the evidence folder.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-lead-sweep-end-states}.log
st=0
bash "$REPO/tests/jg-lead-sweep-end-states.test.sh" >"$LOG" 2>&1 || st=1
grep -q '^FAIL' "$LOG" && st=1
[ "$(grep -c '^ok: ' "$LOG")" -ge 6 ] || st=1
cat "$LOG"
cat >"$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut core/lead-sweep/lead-sweep.sh at this commit"},
 "start":"a fixture home with one resolved lane whose head is on the trunk, one resolved lane not landed, one done lane not landed and one paused lane",
 "steps":["run the lead-sweep check on the home","run the check a second time"],
 "result":"the landed resolved lane is torn down once with no --force; the unlanded resolved lane is left and reported once, and the next beat prints nothing; the done lane and the paused lane are untouched"}
J
exit "$st"
