#!/usr/bin/env bash
# done-done journey: the Evidence card of every landing. The real core/landing-card/landing-card.sh runs over fixture homes
# with a real git clone and the real sign-off-axi on a temp board (core/landing-card/tests/landing-card.test.sh owns the
# cases), and the real bin/jg-trunk.sh lands lanes on a local trunk and records the gate's figures in its proofs row
# (tests/jg-trunk.test.sh owns those cases).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}
cd "$root" || exit 1
rc=0
bash core/landing-card/tests/landing-card.test.sh || rc=1
bash bin/jg-test-run.sh tests/jg-trunk.test.sh > "$out/jg-trunk-test.log" 2>&1 || rc=1
grep '^JG_TEST_SUMMARY ' "$out/jg-trunk-test.log"
cat > "$out/steps.json" <<JSON
{"target": {"version": "$(git rev-parse --short HEAD)"},
 "start": "a fixture home with a real git clone, landing, proof and go-live records and a real sign-off-axi board in a temp folder; a second fixture home with old landings and no backfill marker; a fixture trunk the real lander lands lanes on",
 "steps": ["the card check posts one Evidence card per landing row, showing the gate's scripts run, failed on the first run and seconds, or 'Gate figures: not recorded' when the proofs row has none, and never skips a row with a missing piece",
  "a second run posts nothing; a failed post stops the run and the next run posts the rest",
  "a home with old landings and no marker gets one summary card per old UTC day and no card per old landing; a landing after the marker gets its own card",
  "the real lander lands lanes on a local trunk and writes gate=ran:<scripts>,failed:<first run>,secs:<gate seconds> into its proofs row (seconds only when the gate prints no script summary)"],
 "result": "every landing posts one card with what the lander has, old history is one summary card per day, and the lander's proofs row carries the gate figures"}
JSON
exit "$rc"
