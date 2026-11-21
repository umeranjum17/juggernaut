#!/usr/bin/env bash
# done-done journey: the owner's question is one gate row on the home's tickets tables. The real bin/jg-captain-hold.sh makes it with a
# readable title and its must, his words close it, and no list, ready list or count shows it; spawn and merge blocking see it while open,
# done is refused past it, and an old stamped hold still answers the old way.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-owner-question-gate}.log
st=0
bash "$REPO/tests/jg-captain-hold-gate.test.sh" >"$LOG" 2>&1 || st=1
grep -q '^not ok\|^skip' "$LOG" && st=1
[ "$(grep -c '^ok - ' "$LOG")" -ge 13 ] || st=1
cat "$LOG"
cat >"$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut bin/jg-captain-hold.sh and bin/jg-backlog.sh at this commit"},
 "start":"a fixture home on its tickets tables with a few tickets",
 "steps":["hold a ticket with a must and read the gate, the lists and the counts","try done on the held ticket","answer it with --release and retry the answer","hold with a date, answer, park a hold, arm the board","answer an old stamped hold and reconcile a gate","move old stamped holds to gates and run the pass again"],
 "result":"each question is one gate row with his whole words on it, no list or count shows a gate, and an old stamped hold answers as before"}
J
exit "$st"
