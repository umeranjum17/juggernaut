# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 16. drift raised with --deliver: a producer's drift is one alert and one wake that carries its own words; the same live key rings once; no producer still wakes by itself.
bash "$AL" raise drift prod1 --deliver --ticket tk9 --note "a clone is 2 behind: dirty working tree"; expect_code 0 $? "raise a drift alert"
assert_contains "$(grep drift--prod1 "$Q")" "(P2) at rung 2 for lead: prod1 - a clone is 2 behind: dirty working tree" "the wake names the alert and carries the note"
assert_equals open "$(bash "$AL" word drift--prod1)" "the drift alert is open"
bash "$AL" raise drift prod1 --deliver --note again; assert_equals 1 "$(grep -c 'alert-drift--prod1' "$Q")" "a live key rings once"
bash "$AL" resolve drift--prod1; bash "$AL" raise drift prod1 --deliver --note again; assert_equals 2 "$(grep -c 'alert-drift--prod1' "$Q")" "a resolved key rings again"
assert_equals "" "$(cd "$ROOT" && git grep -nE 'jg_wake_append check "(fleet-autosync-stale|trunk-moved|post-merge-cleanup)|jg_wake_append check pr-poll-retirement' -- bin core)" "the drift producers hold no wake call of their own"
pass "raise --deliver raises the drift alert for a producer and the old per-producer wakes are gone"
