# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 12. A producer of an older wake kind: --rung 1 starts at the worker, --wake/--text deliver that kind keyed by the subject, and --repeat rings an open alert again.
: >"$Q"
al raise lost-worker w1 --rung 1 --wake stale --text "stale: w1 (idle 240s)" --repeat; assert_contains "$OUT" "ring	lost-worker--w1	1	worker" "--rung 1 starts at the worker"
printf '%s\n' "$OUT" | bash "$AL" deliver; assert_contains "$(cat "$Q")" "stale	w1	stale: w1 (idle 240s)" "the stale wake is appended with the window key and the text"
al raise lost-worker w1 --rung 1; assert_equals "" "$OUT" "a second raise without --repeat stays silent"
al raise lost-worker w1 --rung 1 --wake stale --text "stale: w1 (idle 480s)" --repeat; assert_contains "$OUT" "ring	lost-worker--w1	1	worker" "--repeat rings the open alert again"
assert_equals "stale: w1 (idle 480s)" "$(rec lost-worker--w1 text)" "the repeat records the new text"
al raise lost-worker w2 --rung 9; expect_code 2 "$RC" "a rung out of range is a usage error"
pass "a producer of an older wake kind raises at rung 1 and repeats through the alert"
