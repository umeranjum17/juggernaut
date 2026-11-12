# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 3. Quiet facts keep a row quiet; a wait that names the worker starts at rung 1 and Main at rung 3.
al raise stuck-wait q1 --fact wait=owner; assert_equals "" "$OUT" "wait owner is quiet"
al raise stuck-wait q2 --fact wait=outside --fact reason=ci; assert_equals "" "$OUT" "wait outside for ci is quiet"
al raise stuck-wait q3 --fact wait=lead --fact reason=parked; assert_equals "" "$OUT" "reason parked is quiet"
al raise stuck-wait q4 --fact wait=outside --fact reason=dependency; expect_code 1 "$RC" "a wait that is not worker, lead or main is not this alert's state"
al raise stuck-wait w1 --fact wait=worker; assert_contains "$OUT" "	1	worker" "a worker wait starts at rung 1"
al raise stuck-wait w2 --fact wait=main; assert_contains "$OUT" "	3	main" "a Main wait starts at rung 3"
! bash "$AL" list | grep -qE "q[123]\$" || fail "a quiet row left a record"
pass "quiet facts keep a row quiet and the first rung follows the wait"
