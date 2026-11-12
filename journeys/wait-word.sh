#!/usr/bin/env bash
# done-done journey: the wait word replaces the three meanings of `paused`. The status append refuses a paused line with no wait, no
# reason, a word outside the closed lists, or the placeholder date; a hold writes the wait keys on a real Beads store with hold_kind
# kept; the quiet rule keys on reason parked; the brief holds one rule (tests/jg-wait-word.test.sh owns the cases).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
: "${JG_BEADS_TEST_BD:=$(command -v bd)}" "${JG_BEADS_TEST_DOLT:=$(command -v dolt)}"
export JG_BEADS_TEST_BD JG_BEADS_TEST_DOLT
rc=0
bash "$root/tests/jg-wait-word.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a disposable status file, a new Beads store with fixture tickets, and a ship brief scaffolded in a disposable home",
 "steps": ["append paused lines with no wait, a wait with no reason, a wrong word and the placeholder date through the status append", "append whole wait lines", "hold a ticket parked, as an owner question and to a date, and read the wait keys and hold_kind", "unhold and read the wait", "read the brief's wait rule"],
 "result": "each bad line is refused with the new form and writes nothing, a parked hold shows wait lead with reason parked and hold_kind parked, an owner question waits on owner for a decision, a hold to a date waits on outside for the date, unhold ends the wait, and the brief holds one rule"}
JSON
exit "$rc"
