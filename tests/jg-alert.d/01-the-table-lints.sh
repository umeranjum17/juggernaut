# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 1. The ladder is read from the store: the twenty-two rows, six rules and seven limits are all there, and every value jg-alert.sh uses
# equals the one the former alert table held (the fixture is that table as it stood at the base of slice 8y).
BASE="$ROOT/core/item-store/tests/fixtures/ladder-base.tsv"
assert_equals 22 "$(grep -c '^alert	' "$BASE")" "twenty-two alert rows"
assert_equals 6 "$(grep -c '^rule	' "$BASE")" "rules I1 to I6"
al row stuck-wait; assert_contains "$OUT" "P2" "the stuck-wait row is P2"
al row nonsense; expect_code 1 "$RC" "an unknown alert"; assert_contains "$OUT" "known:" "the refusal lists the rows"
while IFS=$'\t' read -r _ name on at prec first quiet; do
  al row "$name"; assert_equals "$name	$on	$at	$prec	$first	$quiet" "$OUT" "row $name equals the former table row"
done < <(grep '^alert	' "$BASE")
while IFS=$'\t' read -r _ kind secs _; do
  al limit "$kind"; assert_equals "$secs" "$OUT" "limit $kind equals the former table value"
done < <(grep '^limit	' "$BASE")
al timers
assert_equals "escalate	300
card	600
realert	600
ready-stall	600" "$OUT" "the wait ladder's timers equal the former table's"
pass "the ladder is read from the store and equals the former table"
