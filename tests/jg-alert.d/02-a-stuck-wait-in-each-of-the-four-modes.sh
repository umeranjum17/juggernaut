# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 2. A stuck wait in each of the four modes: one alert, P2, the rung of the one the wait names, the same row in every mode.
for m in no-mistakes direct-PR local-only local-trunk; do
  al raise stuck-wait "t-$m" --mode "$m" --fact wait=lead --ticket "t-$m"; expect_code 0 "$RC" "raise in $m"
  assert_equals "$(printf 'ring\tstuck-wait--t-%s\t2\tlead' "$m")" "$OUT" "one ring to the lead in $m"
  assert_equals P2 "$(rec "stuck-wait--t-$m" precedence)" "precedence in $m"; assert_equals 2 "$(rec "stuck-wait--t-$m" rung)" "rung in $m"
  assert_equals open "$(bash "$AL" word "stuck-wait--t-$m")" "state in $m"
  assert_equals open "$(bash "$ROOT/core/machines/observers/alert.sh" "stuck-wait--t-$m")" "observer in $m"
done
al raise stuck-wait t-dup --mode local-trunk --fact wait=lead; al raise stuck-wait t-dup --mode local-trunk --fact wait=lead
assert_equals "" "$OUT" "a second raise of a live key rings nothing"
assert_equals 5 "$(bash "$AL" list | wc -l | tr -d ' ')" "five live keys: four modes and one duplicate"
al raise stuck-wait t-bad --mode nonsense --fact wait=lead; expect_code 1 "$RC" "an unknown mode"
al raise stuck-wait t-nowait; expect_code 1 "$RC" "a stuck wait that names no one"
pass "a stuck wait raises one P2 alert at rung 2 in each of the four modes"
