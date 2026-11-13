#!/usr/bin/env bash
# Behavior tests for the hold machine (core/machines/tables/hold.tsv): the settled state and the task with no hold. A call answered with its
# hold released, and a call answered and closed under its hold, are both `closed`; a task with no hold and a task this home does not carry
# are in no state; a closed call has no move, and an illegal move adds one line to the shadow log.
# tests/jg-machine-hold.test.sh owns the lint, the moves and the open states; both share tests/jg-machine-hold-fixture.sh.
# shellcheck source=tests/jg-machine-hold-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-machine-hold-fixture.sh"

hold hold h-closed --title "Choose the sample option for h-closed" --reason "$reason" --repo sample >/dev/null || fail "seed closed"
hold answer h-closed --decision-file "$T/answer.txt" --release >/dev/null || fail "answer and release"
hold hold h-done --title "Choose the sample option for h-done" --reason "$reason" --repo sample >/dev/null || fail "seed closed under the hold"
hold answer h-done --decision-file "$T/answer.txt" >/dev/null || fail "answer and close"
jg_test_backlog "$HOME_DIR" add h-plain "Ordinary sample work" --kind ship --repo sample >/dev/null || fail "seed plain"

assert_equals closed "$(word_of h-closed)" "an answer with the hold released is closed"
assert_equals closed "$(word_of h-done)" "an answer that closed the task is closed"
printf '%s\n' closed > "$T/states.corpus"
jm check hold --corpus "$T/states.corpus"; expect_code 0 "$RC" "closed is a state"
jm show hold h-plain; expect_code 1 "$RC" "a task with no hold is in no state"; assert_contains "$OUT" "no state: the observer printed 'none'" "show names none"
jm show hold h-absent; expect_code 1 "$RC" "a task this home does not carry is in no state"
pass "closed is read for both ways a call is settled, and a task with no hold is in no state"

LOG=$HOME_DIR/data/machine-shadow.log
lines() { [ -f "$LOG" ] && wc -l < "$LOG" || echo 0; }
shadow() { local b; b=$(lines); bash "$ROOT/bin/jg-machine-shadow.sh" hold "$1" "$2" || fail "the shadow helper must always exit 0"; echo $(( $(lines) - b )); }
assert_equals 1 "$(shadow h-closed raised)" "a closed call has no move"
assert_equals 1 "$(shadow h-done answered)" "a closed call cannot be answered again"
assert_contains "$(tail -n 1 "$LOG")" hold "the shadow line names the machine"
pass "a move out of closed adds one shadow line each"
