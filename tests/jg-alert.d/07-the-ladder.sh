# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 7. The ladder: climb waits for the timer and stops at the row's top; rule I6 holds rung 4 for P1 while the owner is away.
al raise line-red lr1 --project p --fact presence=away; assert_contains "$OUT" "	2	lead" "line-red starts at the lead"
now=$(rec line-red--lr1 rung_at)
al climb line-red--lr1 --now $((now + 299)); expect_code 1 "$RC" "a climb before 300 s"
al climb line-red--lr1 --now $((now + 300)); assert_contains "$OUT" "	3	main" "a climb at 300 s reaches Main"
al climb line-red--lr1 --now $((now + 600)); assert_contains "$OUT" "	4	owner" "a climb at 600 s reaches the owner"
al climb line-red--lr1 --now $((now + 900)); expect_code 1 "$RC" "no climb above the top"
al raise security sec1 --fact presence=away; assert_contains "$OUT" "	4	owner" "P0 reaches the owner even while away (I6)"
al raise line-red lr2 --project p2 --fact presence=away; al climb line-red--lr2 --now $(( $(rec line-red--lr2 rung_at) + 300 ))
assert_equals 3 "$(rec line-red--lr2 rung)" "away: the P1 climb stops at Main"
pass "the ladder climbs by its timer, stops at its top, and presence holds rung 4"
