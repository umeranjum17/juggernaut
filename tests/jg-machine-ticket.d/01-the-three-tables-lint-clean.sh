# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 1. The three tables lint clean: 7 stages with 16 moves, delivering with 12 events and 7 sub-states, proving as the composite.
jm check ticket; expect_code 0 "$RC" "ticket lints"; assert_equals "ok ticket: 24 states, 17 edges" "$OUT" "ticket lint golden"
jm check delivering; assert_equals "ok delivering: 9 states, 12 edges" "$OUT" "delivering lint golden"
jm check proving; assert_equals "ok proving: 10 states, 14 edges" "$OUT" "proving lint golden"
assert_equals 7 "$(grep -c '^state	' "$TABLES/ticket.tsv")" "seven stages"
assert_equals 7 "$(grep -c '^state	.*	normal	\|^state	queued	' "$TABLES/delivering.tsv")" "seven sub-states of delivering besides its two ends"
assert_equals 17 "$(bash "$JM" events ticket | wc -l | tr -d ' ')" "seventeen moves"
assert_equals 12 "$(bash "$JM" events delivering | wc -l | tr -d ' ')" "twelve events inside delivering"
assert_equals "file approve start reclaim claim-done claim-done prove-fail prove-pass bypass answer relayed new-head refuse release revert-released close drop" \
  "$(bash "$JM" events ticket | cut -f1 | tr '\n' ' ' | sed 's/ $//')" "the moves, by name"
jm coverage ticket; expect_code 0 "$RC" "every move names a test"
pass "the three tables lint and hold the counted moves"
