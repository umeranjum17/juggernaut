# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 8. The four states: open to acknowledged to open, and resolved is final.
al ack stuck-wait--w1; expect_code 0 "$RC" "ack"; assert_equals acknowledged "$(bash "$AL" word stuck-wait--w1)" "acknowledged"
al climb stuck-wait--w1 --now 99999999999; expect_code 1 "$RC" "an acknowledged alert does not climb"
al reopen stuck-wait--w1; assert_equals open "$(bash "$AL" word stuck-wait--w1)" "reopened"
al resolve stuck-wait--w1; assert_equals resolved "$(bash "$AL" word stuck-wait--w1)" "resolved"
al ack stuck-wait--w1; expect_code 1 "$RC" "a resolved alert cannot be acknowledged"
al raise stuck-wait w1 --fact wait=worker; assert_contains "$OUT" "ring" "a resolved key can ring again as a new episode"
pass "open, acknowledged, inhibited and resolved follow the table"
