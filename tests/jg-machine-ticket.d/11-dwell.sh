# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 11. Dwell: per state, the intervals of a move log, how many are continuous, the median and p90 seconds of those, and the tickets still open there.
DW=$T/dwell-moves.log
{ tab 100 a-1 x start y; tab 110 a-1 y step z; tab 130 a-1 z step w
  tab 300 b-2 x start y; tab 340 b-2 y step z
  tab 500 c-3 x start y; tab 550 c-3 q step z; } > "$DW"
jm dwell ticket --moves "$DW"; expect_code 0 "$RC" "a move log is read"
assert_contains "$OUT" "$(tab state intervals continuous discontinuous median_s p90_s open)" "the header names the columns"
assert_contains "$OUT" "$(tab y 3 2 1 25.0 40.0 0)" "a gap is counted and never timed; median and p90 come from the continuous stays"
assert_contains "$OUT" "$(tab z 1 1 0 20.0 20.0 2)" "a state with a stay shows it, and the tickets still open there"
assert_contains "$OUT" "$(tab w 0 0 0 - - 1)" "a state with no continuous interval prints a dash"
assert_contains "$OUT" "$(tab total 4 3 1 - - 3)" "the total line sums the rows"
jm dwell ticket --moves "$T/no-such-moves.log"; expect_code 2 "$RC" "a missing moves file is a usage error"
jm dwell ticket --bogus x; expect_code 2 "$RC" "an unknown option is a usage error"
pass "dwell counts the stays a move log shows whole and never times a stay with a gap"
