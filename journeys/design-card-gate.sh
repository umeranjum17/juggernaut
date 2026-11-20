#!/usr/bin/env bash
# done-done journey: a design card is one gate on the ticket that raised it, on the home's tickets tables. The real bin/jg-question-card.sh
# posts it with --must design-pick --raised-by <ticket>; the gate carries the card key and no [design-ux] row exists, the ticket's
# merge is refused while it is open, and the board answer closes the gate with his whole words.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-design-card-gate}.log
st=0
bash "$REPO/tests/jg-pending-decision-blocks-work.test.sh" >"$LOG" 2>&1 || st=1
grep -q '^not ok\|^skip' "$LOG" && st=1
grep -q '^ok - replay: the ticket that raised an open design card' "$LOG" || st=1
cat "$LOG"
cat >"$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut bin/jg-question-card.sh and bin/jg-captain-hold.sh at this commit"},
 "start":"a fixture home on its tickets tables, a ticket with a pull request, and a recorded forge",
 "steps":["post a design card with no raising ticket and with an unknown one","post it naming the ticket and read its gate","try the ticket's merge","answer the card on the board and read the gate","merge the ticket"],
 "result":"the card is one gate on the ticket with the card key and no design row, the merge is refused while it is open, and the answer closes the gate with his words"}
J
exit "$st"
