#!/usr/bin/env bash
# Behavior tests for the captain-call machine (core/machines/tables/captain-call.tsv) run by bin/jg-machine.sh: the moves
# out of an answered and a diverged call are taken for real through bin/jg-captain-hold.sh, and each lands on its `to`.
# tests/jg-machine-call.test.sh owns the lint, the states and the listed moves; tests/jg-machine-call-c.test.sh owns the
# moves out of none and open; all three share tests/jg-machine-call-fixture.sh.
# shellcheck source=tests/jg-machine-call-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-machine-call-fixture.sh"

seed_call answered sm8-answered
seed_call diverged sm8-diverged

hold hold sm8-answered --reason "$reason again" >/dev/null || fail "re-hold"
assert_equals open "$(state_of sm8-answered)" "answered -hold-> open"
hold answer sm8-diverged --decision-file "$T/answer.txt" >/dev/null || fail "answer diverged"
assert_equals answered "$(state_of sm8-diverged)" "diverged -answer-> answered"
pass "every move out of answered and diverged lands on its to state"
