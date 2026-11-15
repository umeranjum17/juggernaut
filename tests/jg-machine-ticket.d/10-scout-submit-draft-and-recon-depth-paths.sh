# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 10. Quick and standard Recons have declared proving paths, and a scout's draft is a move of its own with no commit. The real status
# writer's use of submit-draft is driven in tests/jg-lavish-guard.test.sh (test_a_scout_draft_is_submitted_with_no_commit).
jm events ticket; assert_contains "$OUT" "$(printf 'submit-draft\tbuilding\tproving')" "the ticket declares submit-draft from building"
assert_contains "$OUT" "$(printf 'submit-draft\tproving\tproving')" "the ticket declares a revised draft from proving"
jm events proving; assert_contains "$OUT" "$(printf 'quick-pass\tplanned\tsealed')" "the proving table declares the quick path"
assert_contains "$OUT" "$(printf 'standard-pass\tplanned\tsealed')" "the proving table declares the standard path"
assert_contains "$OUT" "$(printf 'hand-to-critic\tplanned\tcritic')" "the deep path stays"
jm edge-check proving planned sealed; expect_code 0 "$RC" "a Recon that needs no critic can seal from planned"
pass "a scout's draft move and the quick and standard Recon paths are declared"
