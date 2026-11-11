#!/usr/bin/env bash
# Behavior tests for the captain-call machine (core/machines/tables/captain-call.tsv) run by bin/jg-machine.sh: the moves
# out of none and open, and a reconcile out of diverged, are taken for real through bin/jg-captain-hold.sh (hold, answer,
# a resolved status line, reconcile close), each lands on its `to`, and no divergence is left once every call is settled.
# tests/jg-machine-call.test.sh owns the lint, the states and the listed moves; tests/jg-machine-call-b.test.sh owns the
# moves out of answered and diverged; all three share tests/jg-machine-call-fixture.sh.
# shellcheck source=tests/jg-machine-call-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-machine-call-fixture.sh"

seed_call none sm8-plain
seed_call open sm8-open
seed_call open sm8-reconciled

hold hold sm8-plain --reason "$reason" >/dev/null || fail "hold a plain task"
assert_equals open "$(state_of sm8-plain)" "none -hold-> open"
hold answer sm8-plain --decision-file "$T/answer.txt" >/dev/null || fail "answer open"
assert_equals answered "$(state_of sm8-plain)" "open -answer-> answered"
status_line sm8-origin "needs-decision [key=sm8-open]: choose the sample option"
status_line sm8-origin "resolved [key=sm8-open]: answered: first option"
assert_equals diverged "$(state_of sm8-open)" "open -resolved-in-log-> diverged"
printf 'The sample option no longer applies.\n' > "$T/evidence.txt"
hold bind sm8-source >/dev/null || fail "bind the reconcile source"
printf '%s\n' sm8-reconciled | hold reconcile-requests --source-id sm8-source --source "captured board result" >/dev/null \
  || fail "request a reconcile"
hold reconcile close sm8-reconciled --evidence-file "$T/evidence.txt" >/dev/null || fail "reconcile close"
assert_equals none "$(state_of sm8-reconciled)" "open -reconcile-> none"
printf 'sm8-open\n' | hold reconcile-requests --source-id sm8-source --source "captured board result" >/dev/null || fail "request a second reconcile"
hold reconcile close sm8-open --evidence-file "$T/evidence.txt" >/dev/null || fail "reconcile close a diverged call"
assert_equals none "$(state_of sm8-open)" "diverged -reconcile-> none"
assert_equals "" "$(diverged_ids)" "no divergence is left once every call is settled"
pass "every move out of none and open, and the reconcile out of diverged, lands on its to state"
