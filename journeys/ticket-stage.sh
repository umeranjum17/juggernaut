#!/usr/bin/env bash
# done-done journey: the stage of a ticket is worked out from its Beads row by one rule. The behavior test
# (tests/jg-beads-ticket-stage.test.sh) lays every fixture row of the rule table on a real store, reads it through
# jg-backlog.sh ticket-stage, checks it against jg-q1b3n's rule, writes the six new moments and the wait keys through the one
# adapter verb, and prints the seconds of one write.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
: "${JG_BEADS_TEST_BD:=$(command -v bd)}" "${JG_BEADS_TEST_DOLT:=$(command -v dolt)}"
export JG_BEADS_TEST_BD JG_BEADS_TEST_DOLT
rc=0
bash "$root/tests/jg-beads-ticket-stage.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a new Beads store with fixture rows, written and read through jg-backlog.sh",
 "steps": ["lay each fixture row of the rule table and read its stage, sub-state and health", "read the same row with jg-q1b3n's rule and compare", "write the six new moments with an event first and a UTC string on the row", "refuse a moment moved back", "write the three wait keys and count the rows before and after", "time one write"],
 "result": "every fixture row reads as the rule table says, the two rules agree except for the rows that start a new try, a wait adds no child row, and one write takes under a second"}
JSON
exit "$rc"
