# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 6. Rule I5: a higher alert for a ticket keeps a lower one for the same ticket quiet.
al raise lost-worker lw1 --ticket tk; assert_contains "$OUT" "ring" "lost-worker (P2) for tk rings"
al raise slow-delivery sd3 --kind ship-delivering --held 300 --ticket tk; assert_equals "" "$OUT" "P3 for the same ticket is covered by the P2"
assert_equals inhibited "$(bash "$AL" word slow-delivery--sd3)" "the P3 is inhibited"
pass "one page for one ticket"
