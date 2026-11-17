# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 8. The four states: open to acknowledged to open, and resolved is final. An acknowledgement never takes the alert's deadline: the
# acknowledged state's own timeout in the machine table is what reopens it, and reopen refuses before it (report section 5.2, ban B10).
al ack stuck-wait--w1; expect_code 0 "$RC" "ack"; assert_equals acknowledged "$(bash "$AL" word stuck-wait--w1)" "acknowledged"
ack_at=$(rec stuck-wait--w1 ack_at)
assert_equals "$((ack_at + 600))" "$(rec stuck-wait--w1 deadline_at)" "the ack keeps the acknowledged state's 10-minute deadline"
al climb stuck-wait--w1 --now $((ack_at + 599)); expect_code 1 "$RC" "an acknowledged alert does not climb before its deadline"
al reopen stuck-wait--w1 --now $((ack_at + 599)); expect_code 1 "$RC" "reopen refuses before the deadline"
al reopen stuck-wait--w1 --now $((ack_at + 600)); assert_contains "$OUT" "ring	stuck-wait--w1	$(rec stuck-wait--w1 rung)	" "its deadline reopens it and rings the rung again"
assert_equals open "$(bash "$AL" word stuck-wait--w1)" "reopened"
al resolve stuck-wait--w1 --proof source:condition-ended; assert_equals resolved "$(bash "$AL" word stuck-wait--w1)" "resolved"
al ack stuck-wait--w1; expect_code 1 "$RC" "a resolved alert cannot be acknowledged"
al raise stuck-wait w1 --fact wait=worker; assert_contains "$OUT" "ring" "a resolved key can ring again as a new episode"
pass "open, acknowledged, inhibited and resolved follow the table, and an ack keeps the deadline"
