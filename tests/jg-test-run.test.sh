#!/usr/bin/env bash
# The runner's speed limits and its whole-gate budget are what stop one slow or
# hung test from holding the pull-request gate, so each limit is proven here on
# its own: the value it reads from config, the failure it produces naming the
# test and its measured elapsed time, and the bound that kills a test which
# would never finish.
# The cases drive the real bin/jg-test-run.sh over throwaway test scripts, so a
# runner that printed the right words without failing, or failed without naming
# the test, would fail them.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/jg-test-run.sh"
TMP_ROOT=$(jg_test_tmproot jg-test-run)

# write_limits <path> <e2e-seconds> <unit-seconds> <gate-seconds>
write_limits() {
  local path=$1
  {
    printf '# test fixture limits\n'
    printf 'e2e_seconds=%s\n' "$2"
    printf 'unit_seconds=%s\n' "$3"
    printf 'gate_wall_seconds=%s\n' "$4"
  } >"$path"
}

# write_script <path> <shell-body>; a test script that prints one ok line and
# then does whatever <shell-body> says.
write_script() {
  local path=$1
  printf '#!/usr/bin/env bash\nprintf "ok - %s\\n"\n%s\n' "$(basename "$path")" "$2" >"$path"
  chmod +x "$path"
}

# print_limits <config-file>: the limits the runner would use, as key=value.
print_limits() {
  TEST_SPEED_LIMITS_FILE=$1 bash "$RUNNER" --show-limits 2>/dev/null
}

test_the_e2e_limit_is_60_seconds_in_config() {
  local out
  out=$(print_limits "$ROOT/defaults/test-speed-limits") ||
    fail 'the runner must report the limits it reads'
  assert_contains "$out" 'e2e_seconds=60' 'the shipped end-to-end limit must be 60 seconds'
  pass 'the shipped end-to-end limit is 60 seconds'
}

test_an_e2e_test_over_its_limit_fails_naming_itself_and_its_time() {
  local limits slow normal out rc=0
  limits="$TMP_ROOT/e2e-limits"
  write_limits "$limits" 2 30 30
  slow="$TMP_ROOT/slow-e2e.test.sh"
  normal="$TMP_ROOT/quick-e2e.test.sh"
  write_script "$slow" 'sleep 4'
  write_script "$normal" 'true'
  out=$(TEST_SPEED_LIMITS_FILE="$limits" bash "$RUNNER" --enforce-test-speed "$normal" "$slow" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an end-to-end test over its limit must fail the run: $out"
  assert_contains "$out" "not ok - $slow took" 'the failure must name the script that overran'
  assert_contains "$out" 'over its 2000ms e2e limit' 'the failure must name the limit it overran'
  assert_contains "$out" 'JG_TEST_SUMMARY total=2 failed=1' 'the overrun must fail the run'
  assert_contains "$out" "ok - $(basename "$normal")" 'a test inside its limit must still pass'
  pass 'an end-to-end test over its limit fails naming itself and its elapsed time'
}

test_the_unit_limit_is_5_seconds_in_config() {
  local out
  out=$(print_limits "$ROOT/defaults/test-speed-limits") ||
    fail 'the runner must report the limits it reads'
  assert_contains "$out" 'unit_seconds=5' 'the shipped unit limit must be 5 seconds'
  pass 'the shipped unit limit is 5 seconds'
}

test_a_unit_test_over_its_limit_fails_naming_itself_and_its_time() {
  local limits slow normal out rc=0
  limits="$TMP_ROOT/unit-limits"
  write_limits "$limits" 30 1 30
  slow="$TMP_ROOT/slow-unit.test.sh"
  normal="$TMP_ROOT/quick-unit.test.sh"
  write_script "$slow" 'sleep 3'
  write_script "$normal" 'true'
  out=$(TEST_SPEED_LIMITS_FILE="$limits" bash "$RUNNER" --enforce-test-speed "$normal" "$slow" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a unit test over its limit must fail the run: $out"
  assert_contains "$out" "not ok - $slow took" 'the failure must name the script that overran'
  assert_contains "$out" 'over its 1000ms unit limit' 'the failure must name the limit it overran'
  assert_contains "$out" 'JG_TEST_SUMMARY total=2 failed=1' 'the overrun must fail the run'
  assert_contains "$out" "ok - $(basename "$normal")" 'a test inside its limit must still pass'
  pass 'a unit test over its limit fails naming itself and its elapsed time'
}

test_the_gate_wall_limit_is_10_minutes_in_config() {
  local out
  out=$(print_limits "$ROOT/defaults/test-speed-limits") ||
    fail 'the runner must report the limits it reads'
  assert_contains "$out" 'gate_wall_seconds=600' 'the shipped gate budget must be 600 seconds'
  pass 'the shipped whole-gate budget is 10 minutes'
}

test_a_run_past_the_gate_budget_fails_without_starting_the_next_test() {
  local limits first second marker out rc=0
  limits="$TMP_ROOT/gate-limits"
  write_limits "$limits" 30 30 1
  first="$TMP_ROOT/gate-first.test.sh"
  second="$TMP_ROOT/gate-second.test.sh"
  marker="$TMP_ROOT/gate-second.ran"
  write_script "$first" 'sleep 2'
  write_script "$second" "touch '$marker'"
  out=$(TEST_SPEED_LIMITS_FILE="$limits" bash "$RUNNER" --gate "$first" "$second" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a run past its gate budget must fail: $out"
  assert_contains "$out" "not ok - $second was not run" 'the failure must name the test the budget stopped'
  assert_contains "$out" 'wall budget of 1000ms' 'the failure must name the configured budget'
  [ ! -e "$marker" ] || fail 'a test the spent budget stopped must not run'
  pass 'a run past the gate budget fails without starting the next test'
}

test_a_hanging_test_is_killed_and_reported_instead_of_holding_the_run() {
  local limits hung rc=0 started ended
  limits="$TMP_ROOT/hang-limits"
  write_limits "$limits" 30 1 30
  hung="$TMP_ROOT/hangs-unit.test.sh"
  write_script "$hung" 'while :; do sleep 0.2; done'
  started=$(date +%s)
  out=$(TEST_SPEED_LIMITS_FILE="$limits" bash "$RUNNER" --enforce-test-speed "$hung" 2>&1) || rc=$?
  ended=$(date +%s)
  [ "$rc" -ne 0 ] || fail "a hanging test must fail the run: $out"
  assert_contains "$out" "not ok - $hung took" 'the terminated script must be named'
  assert_contains "$out" 'over its 1000ms unit limit' 'the bound that killed it must be named'
  [ "$((ended - started))" -lt 20 ] || fail "the hang must be bounded well under a gate, took $((ended - started))s"
  pass 'a hanging test is killed and reported instead of holding the run'
}

test_a_test_within_its_limits_is_unaffected() {
  local limits fast out rc=0
  limits="$TMP_ROOT/normal-limits"
  write_limits "$limits" 2 1 5
  fast="$TMP_ROOT/normal-unit.test.sh"
  write_script "$fast" 'true'
  out=$(TEST_SPEED_LIMITS_FILE="$limits" bash "$RUNNER" --gate "$fast" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a test inside its limits must pass under the gate contract: $out"
  assert_contains "$out" "ok - $(basename "$fast")" 'the passing test must report ok'
  assert_contains "$out" 'JG_TEST_SUMMARY total=1 failed=0' 'the run must report one passing test'
  pass 'a test within its limits is unaffected'
}

test_the_e2e_limit_is_60_seconds_in_config
test_an_e2e_test_over_its_limit_fails_naming_itself_and_its_time
test_the_unit_limit_is_5_seconds_in_config
test_a_unit_test_over_its_limit_fails_naming_itself_and_its_time
test_the_gate_wall_limit_is_10_minutes_in_config
test_a_run_past_the_gate_budget_fails_without_starting_the_next_test
test_a_hanging_test_is_killed_and_reported_instead_of_holding_the_run
test_a_test_within_its_limits_is_unaffected

printf 'all %s\n' 'jg-test-run limit tests passed'
