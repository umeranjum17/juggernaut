# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 6. The 21 records of the pull request style get their targets; a changed target is named.
jm records ticket-words "$ROOT/core/machines/corpus/pr-records.tsv"; expect_code 0 "$RC" "records"; assert_equals "ok ticket-words: 21 records, 0 differ" "$OUT" "records golden"
sed '3s/released/closed/' "$ROOT/core/machines/corpus/pr-records.tsv" > "$T/records.tsv"
jm records ticket-words "$T/records.tsv"; expect_code 1 "$RC" "a wrong target"; assert_contains "$OUT" "differs " "records name the record"
pass "the 21 pull request records get their targets"
