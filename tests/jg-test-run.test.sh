#!/usr/bin/env bash
# The runner's speed limits report a slow test by name and its measured time and
# never fail or kill it; its whole-gate budget and its per-script bound are what
# stop one hung test from holding the pull-request gate. Each is proven here on
# its own: the value it reads from config, the warning it produces, the budget
# that stops the run, and the bound that kills a test which would never finish.
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

test_required_shards_keep_the_union_and_a_failed_shard() {
  local fixture=$TMP_ROOT/required out rc=0
  mkdir -p "$fixture/tests"
  cp -R "$ROOT/bin" "$fixture/bin"
  cp -R "$ROOT/defaults" "$fixture/defaults"
  cp "$ROOT/tests/git-config-helpers.sh" "$fixture/tests/"
  jg_git_init_commit "$fixture"
  git -C "$fixture" add bin defaults tests/git-config-helpers.sh
  git -C "$fixture" -c user.name=t -c user.email=t@example.invalid commit -qm 'fixture scaffolding'
  write_script "$fixture/tests/required-feature.test.sh" 'echo "Umer fixture failure"; exit 1'
  git -C "$fixture" add tests
  git -C "$fixture" -c user.name=t -c user.email=t@example.invalid commit -qm 'fixture feature'
  out=$(bash "$fixture/bin/jg-test-run.sh" --required-shards HEAD^ "$TMP_ROOT/required-results" 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "a failed required shard must refuse: $out"
  jq -e '.summary.lanes == 8 and .summary.total == 1 and .summary.failed == 1 and .summary.failed_lanes == 1 and (.scripts | length) == 1' \
    "$TMP_ROOT/required-results/required.json" >/dev/null || fail "required aggregate lost a shard, failure or selected script: $out"
  pass 'the eight required shards keep the selected union and retain a failed shard in the aggregate'
}

test_shards_split_a_selection_without_losing_or_repeating_a_script() {
  local scripts k out all seen rc=0
  scripts="tests/jg-ship-local.test.sh tests/jg-pr-wait.test.sh tests/jg-brief.test.sh tests/jg-send-inbox.test.sh tests/jg-prompt-gate.test.sh tests/jg-owner-rules.test.sh tests/jg-mail.test.sh"
  # shellcheck disable=SC2086  # the script list is a deliberate word split
  all=$(bash "$RUNNER" --list $scripts | LC_ALL=C sort)
  seen=
  for k in 1 2 3; do
    # shellcheck disable=SC2086
    out=$(bash "$RUNNER" --list --shard "${k}of3" $scripts) || fail "shard ${k}of3 was refused: $out"
    # shellcheck disable=SC2086
    [ "$out" = "$(bash "$RUNNER" --list --shard "${k}of3" $scripts)" ] || fail "shard ${k}of3 is not the same on a second run"
    seen=$(printf '%s\n%s\n' "$seen" "$out")
  done
  assert_equals "$all" "$(printf '%s\n' "$seen" | sed '/^$/d' | LC_ALL=C sort)" \
    'the shards together must be exactly the selection, each script once'
  out=$(bash "$RUNNER" --shard 3of3 tests/jg-pr-wait.test.sh 2>&1) || rc=$?
  assert_equals 0 "$rc" "a shard with nothing in it must pass: $out"
  assert_contains "$out" 'nothing to run' 'an empty shard must say it ran nothing'
  for k in 0of3 4of3 1of0 abc 2of; do
    rc=0
    bash "$RUNNER" --list --shard "$k" tests/jg-pr-wait.test.sh >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "the shard spec '$k' was accepted"
  done
  pass 'shards split a selection into disjoint parts that together are the whole of it, and bad specs are refused'
}

test_the_e2e_limit_is_60_seconds_in_config() {
  local out
  out=$(print_limits "$ROOT/defaults/test-speed-limits") ||
    fail 'the runner must report the limits it reads'
  assert_contains "$out" 'e2e_seconds=60' 'the shipped end-to-end limit must be 60 seconds'
  pass 'the shipped end-to-end limit is 60 seconds'
}

test_an_e2e_test_over_its_limit_warns_naming_itself_and_its_time() {
  local limits slow normal out rc=0
  limits="$TMP_ROOT/e2e-limits"
  write_limits "$limits" 2 30 30
  slow="$TMP_ROOT/slow-e2e.test.sh"
  normal="$TMP_ROOT/quick-e2e.test.sh"
  write_script "$slow" 'sleep 4'
  write_script "$normal" 'true'
  out=$(TEST_SPEED_LIMITS_FILE="$limits" bash "$RUNNER" --enforce-test-speed "$normal" "$slow" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "an end-to-end test over its limit only warns and must not fail the run: $out"
  assert_contains "$out" "$slow took" 'the warning must name the script that overran'
  assert_contains "$out" 'over its 2000ms e2e limit' 'the warning must name the limit it overran'
  assert_contains "$out" 'JG_TEST_SUMMARY total=2 failed=0' 'an e2e overrun must not fail the run'
  assert_contains "$out" "ok - $(basename "$slow")" 'the overrunning test must be left to finish and report its own result'
  pass 'an end-to-end test over its limit warns naming itself and its elapsed time'
}

test_the_unit_limit_is_5_seconds_in_config() {
  local out
  out=$(print_limits "$ROOT/defaults/test-speed-limits") ||
    fail 'the runner must report the limits it reads'
  assert_contains "$out" 'unit_seconds=15' 'the shipped unit limit floor must be 15 seconds'
  pass 'the shipped unit limit floor is 15 seconds'
}

test_a_unit_test_over_its_limit_warns_naming_itself_and_its_time() {
  local limits slow normal out rc=0
  limits="$TMP_ROOT/unit-limits"
  write_limits "$limits" 30 1 30
  slow="$TMP_ROOT/slow-unit.test.sh"
  normal="$TMP_ROOT/quick-unit.test.sh"
  write_script "$slow" 'sleep 3'
  write_script "$normal" 'true'
  out=$(TEST_SPEED_LIMITS_FILE="$limits" bash "$RUNNER" --enforce-test-speed "$normal" "$slow" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a unit test over its limit only warns and must not fail the run: $out"
  assert_contains "$out" "$slow took" 'the warning must name the script that overran'
  assert_contains "$out" 'over its 1000ms unit limit' 'the warning must name the limit it overran'
  assert_contains "$out" 'JG_TEST_SUMMARY total=2 failed=0' 'a unit overrun must not fail the run'
  pass 'a unit test over its limit warns naming itself and its elapsed time'
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

test_a_wall_failure_with_no_functional_failure_stays_red_in_aggregate() {
  local script=$TMP_ROOT/wall-only.test.sh json=$TMP_ROOT/wall-only.json rc=0
  write_script "$script" 'sleep 2'
  bash "$RUNNER" --gate --max-wall-ms 1000 --json "$json" "$script" > "$TMP_ROOT/wall-only.log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail 'a wall-only overrun must fail the command'
  jq -e '.summary.failed == 0 and .summary.exit != 0' "$json" >/dev/null || fail 'timing JSON must retain the failed gate verdict with zero functional failures'
  bash "$RUNNER" --aggregate-json "$TMP_ROOT/wall-aggregate.json" "$json" >/dev/null || fail 'the timing aggregation must run'
  jq -e '.summary.failed == 0 and .summary.failed_lanes == 1' "$TMP_ROOT/wall-aggregate.json" >/dev/null || fail 'the aggregate must not turn a wall-only failure green'
  pass 'a wall-only gate failure stays red in its timing artifact and aggregate'
}

test_a_hanging_test_is_killed_and_reported_instead_of_holding_the_run() {
  local limits hung rc=0 started ended
  limits="$TMP_ROOT/hang-limits"
  write_limits "$limits" 30 30 30
  hung="$TMP_ROOT/hangs-e2e.test.sh"
  write_script "$hung" 'while :; do sleep 0.2; done'
  started=$(date +%s)
  out=$(TEST_SPEED_LIMITS_FILE="$limits" bash "$RUNNER" --enforce-test-speed --per-script-timeout-secs 1 "$hung" 2>&1) || rc=$?
  ended=$(date +%s)
  [ "$rc" -ne 0 ] || fail "a hanging test must fail the run: $out"
  assert_contains "$out" "not ok - $hung exceeded the per-script bound of 1s" 'the terminated script and the bound that killed it must be named'
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

test_the_pinned_tools_default_to_the_ones_on_path() {
  local bin out script
  bin="$TMP_ROOT/beads-bin"; mkdir -p "$bin"
  for t in bd dolt go; do printf '#!/bin/sh\n' > "$bin/$t"; chmod +x "$bin/$t"; done
  script="$TMP_ROOT/beads-env.test.sh"
  # shellcheck disable=SC2016  # the body is written out verbatim and expands when the runner runs it
  write_script "$script" 'echo "bd=${JG_BEADS_TEST_BD:-unset} dolt=${JG_BEADS_TEST_DOLT:-unset} go=${JG_SPAWN_CORE_GO:-unset}"'
  out=$(env -u JG_BEADS_TEST_BD -u JG_BEADS_TEST_DOLT -u JG_SPAWN_CORE_GO PATH="$bin:$PATH" bash "$RUNNER" "$script" 2>&1) || fail "the run failed: $out"
  assert_contains "$out" "bd=$bin/bd dolt=$bin/dolt go=$bin/go" 'an unset pin must default to the tool on PATH'
  out=$(env JG_BEADS_TEST_BD=/pinned/bd JG_BEADS_TEST_DOLT=/pinned/dolt JG_SPAWN_CORE_GO=/pinned/go PATH="$bin:$PATH" bash "$RUNNER" "$script" 2>&1) || fail "the run failed: $out"
  assert_contains "$out" 'bd=/pinned/bd dolt=/pinned/dolt go=/pinned/go' 'a pin the caller exported must stay'
  pass 'the pinned tools default to the ones on PATH and an exported pin stays'
}

test_a_weight_cap_defers_slow_suites_and_names_them() {
  local out
  out=$(bash "$RUNNER" --list --max-weight-ms 60000 tests/jg-teardown.test.sh tests/jg-ship-local.test.sh 2>&1) || fail "a capped list was refused: $out"
  assert_contains "$out" 'deferred to the post-merge lane' 'a deferred suite must be named'
  assert_contains "$out" 'tests/jg-ship-local.test.sh' 'a fast suite must stay selected'
  case $(printf '%s\n' "$out" | grep -v deferred) in
    *jg-teardown*) fail "the slow suite stayed in the capped selection: $out" ;;
  esac
  pass 'a weight cap defers slow suites and names them'
}

test_required_shards_keep_the_union_and_a_failed_shard
test_shards_split_a_selection_without_losing_or_repeating_a_script
test_the_e2e_limit_is_60_seconds_in_config
test_an_e2e_test_over_its_limit_warns_naming_itself_and_its_time
test_the_unit_limit_is_5_seconds_in_config
test_a_unit_test_over_its_limit_warns_naming_itself_and_its_time
test_the_gate_wall_limit_is_10_minutes_in_config
test_a_run_past_the_gate_budget_fails_without_starting_the_next_test
test_a_wall_failure_with_no_functional_failure_stays_red_in_aggregate
test_a_hanging_test_is_killed_and_reported_instead_of_holding_the_run
test_a_test_within_its_limits_is_unaffected
test_a_weight_cap_defers_slow_suites_and_names_them
test_the_pinned_tools_default_to_the_ones_on_path

printf 'all %s\n' 'jg-test-run limit tests passed'
