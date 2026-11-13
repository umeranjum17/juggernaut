# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 4. Rule I1: with supervision-down open for a home, the wait alerts of that home are inhibited and ring nothing; another home still rings.
al raise supervision-down h1 --home h1 --fact beats=2; assert_contains "$OUT" "	1	worker" "supervision-down starts at rung 1"
al raise stuck-wait s-h1 --home h1 --fact wait=lead; assert_equals "" "$OUT" "supervision-down open: no ring"
assert_equals inhibited "$(bash "$AL" word stuck-wait--s-h1)" "the covered alert is recorded inhibited"
assert_equals supervision-down--h1 "$(rec stuck-wait--s-h1 covered_by)" "it names its cover"
al raise stuck-wait s-h2 --home h2 --fact wait=lead; assert_contains "$OUT" "ring" "another home still rings"
al resolve supervision-down--h1; assert_contains "$OUT" "ring	stuck-wait--s-h1	2	lead" "resolving the cover releases the covered alert with a ring"
assert_equals open "$(bash "$AL" word stuck-wait--s-h1)" "the released alert is open"
pass "supervision-down open raises no wait alert in its home, and resolving it releases them"
