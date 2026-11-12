# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 5. Fires-at and limits by kind: slow-delivery needs a kind; a state that has not held long enough is refused.
al limit ship-delivering; assert_equals 300 "$OUT" "ship delivering limit"; al limit ship-proving; assert_equals 900 "$OUT" "ship proving limit"
al raise slow-delivery sd1; expect_code 1 "$RC" "slow-delivery with no kind"
al raise slow-delivery sd1 --kind ship-delivering --held 299; expect_code 1 "$RC" "held 299 s of 300"
al raise slow-delivery sd1 --kind ship-delivering --held 300 --ticket tk; assert_contains "$OUT" "ring	slow-delivery--sd1	1	worker" "held 300 s rings the worker first (the tick climb is not built)"
al raise slow-delivery sd2 --kind ship-delivering --held 400 --fact wait=outside --fact reason=ci; assert_equals "" "$OUT" "wait outside for ci keeps slow-delivery quiet"
pass "limits by kind gate the fires-at time"
