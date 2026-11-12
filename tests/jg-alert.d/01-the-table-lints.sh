# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 1. The table lints, and the nineteen rows, six rules and seven limits are all there.
OUT=$(bash "$JM" check alert 2>&1); expect_code 0 $? "alert table lint"; assert_contains "$OUT" "5 states, 8 edges" "the alert machine has five states"
assert_equals 19 "$(grep -c '^alert	' "$ROOT/core/machines/styles/alert-table.tsv")" "nineteen alert rows"
assert_equals 6 "$(grep -c '^rule	' "$ROOT/core/machines/styles/alert-table.tsv")" "rules I1 to I6"
al row stuck-wait; assert_contains "$OUT" "P2" "the stuck-wait row is P2"
al row nonsense; expect_code 1 "$RC" "an unknown alert"; assert_contains "$OUT" "known:" "the refusal lists the rows"
pass "the table lints and holds its rows"
