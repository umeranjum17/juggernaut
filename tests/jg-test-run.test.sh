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
# This suite's own runs queue among themselves, never behind the machine's real test runs.
export JG_TEST_HOST_SLOTS="$TMP_ROOT/run-slots"

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

# required_fixture <dir> <shell-body> [<count>]: a repository whose last commit adds one test script,
# tests/required-feature.test.sh, that prints its ok line and then runs <shell-body>, so
# --required-shards HEAD^ selects exactly that script; with <count>, it adds that many such scripts
# (required-feature-2.test.sh and on), and nine put two in the first shard.
required_fixture() {
  local fixture=$1 i
  mkdir -p "$fixture/tests"
  cp -R "$ROOT/bin" "$fixture/bin"
  cp -R "$ROOT/defaults" "$fixture/defaults"
  cp "$ROOT/tests/git-config-helpers.sh" "$fixture/tests/"
  jg_git_init_commit "$fixture"
  git -C "$fixture" add bin defaults tests/git-config-helpers.sh
  git -C "$fixture" -c user.name=t -c user.email=t@example.invalid commit -qm 'fixture scaffolding'
  write_script "$fixture/tests/required-feature.test.sh" "$2"
  i=2
  while [ "$i" -le "${3:-1}" ]; do write_script "$fixture/tests/required-feature-$i.test.sh" "$2"; i=$((i + 1)); done
  git -C "$fixture" add tests
  git -C "$fixture" -c user.name=t -c user.email=t@example.invalid commit -qm 'fixture feature'
}

test_required_shards_keep_the_union_and_a_failed_shard() {
  local fixture=$TMP_ROOT/required out rc=0
  required_fixture "$fixture" 'echo "Umer fixture failure"; exit 1'
  out=$(bash "$fixture/bin/jg-test-run.sh" --required-shards HEAD^ "$TMP_ROOT/required-results" 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "a failed required shard must refuse: $out"
  jq -e '.summary.lanes == 8 and .summary.total == 1 and .summary.failed == 1 and .summary.failed_lanes == 1 and (.scripts | length) == 1' \
    "$TMP_ROOT/required-results/required.json" >/dev/null || fail "required aggregate lost a shard, failure or selected script: $out"
  pass 'the eight required shards keep the selected union and retain a failed shard in the aggregate'
}

# A script tests/gate-quarantine.tsv lists is selected by the gate's changed files but never run: the gate lists it with its reason and
# still passes, so one hung or flaky script cannot hold a landing. The same script outside the quarantine fails the gate (the case above).
test_a_quarantined_script_is_listed_not_run_and_the_gate_passes() {
  local fixture=$TMP_ROOT/quarantine out rc=0
  # shellcheck disable=SC2016 # the body runs in the fixture script, not here
  required_fixture "$fixture" 'echo "Umer hung fixture"; touch "$(dirname "$0")/ran-marker"; exit 1'
  printf 'tests/required-feature.test.sh\thung under --jobs 1 (fixture)\n' >"$fixture/tests/gate-quarantine.tsv"
  git -C "$fixture" add tests/gate-quarantine.tsv
  git -C "$fixture" -c user.name=t -c user.email=t@example.invalid commit -qm 'quarantine the feature script'
  printf '# touched\n' >>"$fixture/tests/required-feature.test.sh"
  git -C "$fixture" -c user.name=t -c user.email=t@example.invalid commit -qam 'touch the quarantined script'
  out=$(bash "$fixture/bin/jg-test-run.sh" --required-shards HEAD^ "$TMP_ROOT/quarantine-results" 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "a quarantined script held the gate: rc=$rc $out"
  assert_contains "$out" 'JG_TEST_QUARANTINED tests/required-feature.test.sh reason=hung under --jobs 1 (fixture)' 'the gate must record the quarantine with its reason'
  [ ! -e "$fixture/tests/ran-marker" ] || fail "the quarantined script ran: $out"
  jq -e '.summary.total == 0 and .summary.failed == 0' "$TMP_ROOT/quarantine-results/required.json" >/dev/null || fail "the aggregate counted the quarantined script: $out"
  pass 'a quarantined script is listed with its reason, not run, and the gate still passes'
}

# trunk tip 52dd4fd44 went red as "aggregate input not found: shard-1.json", on all eight shards at once: the commit range held
# bin/jg-digest-cap-lib.sh, which no test names, so each shard stopped at selection ("no changed-test mapping") before it
# wrote its result, and the aggregate then reported the missing file in place of the real cause. A shard that stops for any
# reason writes a failed result that names the shard and the cause, so the aggregate reads a verdict and not a missing file.
test_a_shard_that_stops_before_its_result_still_writes_a_failed_result() {
  local fixture=$TMP_ROOT/orphan res=$TMP_ROOT/orphan-results out rc=0
  required_fixture "$fixture" 'exit 0'
  printf '#!/usr/bin/env bash\n:\n' >"$fixture/bin/jg-orphan-lib.sh"
  git -C "$fixture" add bin/jg-orphan-lib.sh
  git -C "$fixture" -c user.name=t -c user.email=t@example.invalid commit -q --amend --no-edit
  out=$(JG_REQUIRED_SHARD_WALL_MS=1 bash "$fixture/bin/jg-test-run.sh" --required-shards HEAD^ "$res" 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "shards that stopped before their result must refuse with exit 1: rc=$rc $out"
  assert_not_contains "$out" 'aggregate input not found' 'a missing shard result must never reach the aggregate'
  assert_contains "$out" 'no changed-test mapping for source path: bin/jg-orphan-lib.sh' 'the real cause stays in the log'
  [ "$(printf '%s\n' "$out" | grep -c '^jg-test-run: shard [1-8]of8 stopped with exit 2 before it wrote its result')" = 8 ] ||
    fail "each shard must be named with its exit status: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^JG_TEST_OVERRUN budget_ms=1 duration_ms=[0-9]* load=[^ ]* cpus=[0-9]* selection=shard=[1-8]of8$')" = 8 ] ||
    fail "each shard past its budget must be named in the log, even without a result: $out"
  jq -e '.summary.lanes == 8 and .summary.failed_lanes == 8 and ([.lanes[].selection] | map(test("^shard=[1-8]of8$")) | all)' \
    "$res/required.json" >/dev/null || fail "the aggregate must hold one failed verdict per shard: $out"
  pass 'a shard that stops before its result writes a failed result naming the shard, and an overrun is still named'
}

# A shard over its wall-clock budget was slowed by the machine, not failed by a test, so it is a warning and never a red,
# and the budget never cuts it short: trunk-v3 went red at 20eb94ae6054 with all eight shards at 601 to 651 s of 600 s,
# failed=0, and the budget had stopped each shard before about half its scripts ran. A failed test stays a red.
test_a_required_shard_over_its_budget_is_a_warning_and_runs_every_script() {
  local res out rc
  required_fixture "$TMP_ROOT/slow" 'sleep 3' 9
  res=$TMP_ROOT/slow-results rc=0
  out=$(JG_REQUIRED_SHARD_WALL_MS=2000 bash "$TMP_ROOT/slow/bin/jg-test-run.sh" --required-shards HEAD^ "$res" 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "shards that pass every script and only run over their budget must pass: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^JG_TEST_BEGIN ')" = 9 ] || fail "every selected script must run once, the budget never cutting a shard short: $out"
  assert_not_contains "$out" 'was not run' 'no script may be left unrun for the budget'
  [ "$(printf '%s\n' "$out" | grep -c '^JG_TEST_OVERRUN budget_ms=2000 duration_ms=[0-9]* load=[^ ]* cpus=[0-9]* selection=.*shard=[1-8]of8')" = 8 ] ||
    fail "each shard over its budget must print one overrun warning with the host load: $out"
  assert_contains "$out" 'over its 2000ms wall-clock budget, at host load' 'the overrun must be named with the host load'
  jq -e '.summary.failed_lanes == 0 and .summary.total == 9 and .summary.failed == 0' "$res/required.json" >/dev/null ||
    fail "the aggregate must count every script and no failed shard: $out"

  required_fixture "$TMP_ROOT/slow-red" 'echo "Umer fixture failure"; sleep 3; exit 1'
  res=$TMP_ROOT/slow-red-results rc=0
  out=$(JG_REQUIRED_SHARD_WALL_MS=2000 bash "$TMP_ROOT/slow-red/bin/jg-test-run.sh" --required-shards HEAD^ "$res" 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "a shard with a failed test must stay red, over its budget or not: $out"
  assert_contains "$out" 'JG_TEST_OVERRUN budget_ms=2000' 'the failed shard over its budget still records its overrun'
  [ "$(printf '%s\n' "$out" | grep -c '^JG_TEST_BEGIN ')" = 1 ] || fail "the failed test must run exactly once: $out"
  jq -e '.summary.failed_lanes == 1 and .summary.failed == 1' "$res/required.json" >/dev/null ||
    fail "the aggregate must keep the failed test: $out"
  pass 'a required shard over its budget runs every script and is a warning with the host load; a failed test stays red'
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
  assert_contains "$out" "not ok - $hung exceeded the per-script bound of 1s with no output for 1s and was terminated as hung" 'the hung script and the bound that ended it must be named'
  [ "$((ended - started))" -lt 20 ] || fail "the hang must be bounded well under a gate, took $((ended - started))s"
  pass 'a hanging test is killed and reported instead of holding the run'
}

# The per-script bound advises: a script that outruns it while it keeps writing output is slow, not hung, and its own
# result stands (PR 813, Changed tests 8: tests/jg-test-run.test.sh was killed at 132 s only because eight shards ran at once).
test_a_slow_passing_script_past_the_per_script_bound_warns_and_passes() {
  local slow rc=0 out
  slow="$TMP_ROOT/slow-but-alive.test.sh"
  # shellcheck disable=SC2016  # the loop variable expands in the script under test
  write_script "$slow" 'for i in 1 2 3 4 5; do echo "ok - step $i"; sleep 0.7; done'
  out=$(bash "$RUNNER" --per-script-timeout-secs 1 "$slow" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a slow script that still passes must exit 0: $out"
  assert_contains "$out" 'JG_TEST_SLOW' 'the advise line must be printed'
  assert_contains "$out" 'ran past the per-script bound of 1s and was not stopped' 'the advise line must say the script was not stopped'
  assert_contains "$out" 'shards that run side by side slow each other' 'the advise line must name the shared-load cause'
  assert_not_contains "$out" 'terminated as hung' 'a script that keeps writing is not hung'
  assert_contains "$out" 'ok - step 5' 'the slow script must run to its end'
  pass 'a slow script that keeps writing past the per-script bound warns and passes'
}

test_a_slow_failing_script_past_the_per_script_bound_stays_red() {
  local slow rc=0 out
  slow="$TMP_ROOT/slow-fails.test.sh"
  # shellcheck disable=SC2016  # the loop variable expands in the script under test
  write_script "$slow" 'for i in 1 2 3; do echo "step $i"; sleep 0.7; done; exit 3'
  out=$(bash "$RUNNER" --per-script-timeout-secs 1 "$slow" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a slow script that fails must stay red: $out"
  assert_not_contains "$out" 'terminated as hung' 'a failing slow script is a plain failure, not a hang'
  pass 'a slow script that fails past the per-script bound stays red'
}

test_the_gate_stops_a_hung_script_with_its_children_and_temp_folder_without_a_flag() {
  local limits hung rc=0 out marker pidfile child
  limits="$TMP_ROOT/default-bound-limits"
  { write_limits "$limits" 30 30 30; printf 'script_timeout_seconds=2\n' >>"$limits"; }
  marker="jgdefaultbound$$"
  pidfile="$TMP_ROOT/default-bound.pids"
  hung="$TMP_ROOT/default-bound-hang.test.sh"
  write_script "$hung" "mkdir -p \"\$TMPDIR/scratch-$marker\"
setsid sleep 1234 >/dev/null 2>&1 < /dev/null &
echo \$! > '$pidfile'
sleep 1235 &
echo \$! >> '$pidfile'
echo \"\$TMPDIR\" > '$pidfile.tmpdir'
sleep 1236"
  out=$(TEST_SPEED_LIMITS_FILE="$limits" bash "$RUNNER" --gate "$hung" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a hung script must fail the gate: $out"
  assert_contains "$out" "JG_TEST_TIMEOUT script=$hung bound_secs=2" 'the gate must name the script that timed out and the bound'
  while read -r child; do
    ! kill -0 "$child" 2>/dev/null || fail "child $child of the hung script is still running"
  done <"$pidfile"
  [ ! -e "$(cat "$pidfile.tmpdir")" ] || fail 'the hung script temp folder must be removed'
  pass 'the gate stops a hung script with its children and temp folder without a flag'
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

# A branch that retires a journey with its test (go-shell GS6 deleted the Dapr worker's journey and
# test) must still select its changed tests: the deleted journey has no owner left, so it selects
# nothing, while a deleted journey another test still names selects that test.
test_a_deleted_journey_does_not_refuse_the_changed_selection() {
  local fixture=$TMP_ROOT/retire out rc=0
  required_fixture "$fixture" 'true'
  mkdir -p "$fixture/journeys"
  printf 'bash tests/retired.test.sh\n' >"$fixture/journeys/retired.sh"
  printf 'bash tests/kept.test.sh\n' >"$fixture/journeys/named.sh"
  write_script "$fixture/tests/retired.test.sh" '# owns journeys/retired.sh'
  write_script "$fixture/tests/kept.test.sh" '# still names journeys/named.sh'
  git -C "$fixture" add journeys tests
  git -C "$fixture" -c user.name=t -c user.email=t@example.invalid commit -qm 'fixture journeys'
  git -C "$fixture" rm -q journeys/retired.sh journeys/named.sh tests/retired.test.sh
  git -C "$fixture" -c user.name=t -c user.email=t@example.invalid commit -qm 'retire the journeys'
  out=$(bash "$fixture/bin/jg-test-run.sh" --list --changed --base HEAD^ 2>&1) || rc=$?
  assert_equals 0 "$rc" "a deleted journey must not refuse the changed selection: $out"
  assert_equals 'tests/kept.test.sh' "$out" 'a deleted journey a test still names must select that test, and nothing else'
  pass 'a deleted journey selects only a test that still names it and never refuses the changed selection'
}

# The hosted job (--hosted) leaves out a script tests/hosted-needs.tsv lists while a tool it needs is not on the runner's PATH,
# and names it; the same selection without the flag still lists every one, so the scripts run on our host.
test_the_hosted_selection_drops_scripts_whose_tool_the_runner_lacks() {
  local bin=$TMP_ROOT/hosted-bin t hosted local_sel s
  mkdir -p "$bin"
  for t in bash awk sed grep git sort cat env dirname basename mktemp tr head tail wc date ls rm mkdir cut uniq xargs find ps sleep sh; do
    command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$bin/$t"
  done
  hosted=$(PATH=$bin /bin/bash "$RUNNER" --list --hosted tests/jg-trunk-release-open-pr.test.sh tests/jg-browser-reaper.test.sh \
    tests/jg-trunk-rollover.test.sh tests/jg-ship-local.test.sh 2>&1) || fail "a hosted list was refused: $hosted"
  local_sel=$(PATH=$bin /bin/bash "$RUNNER" --list tests/jg-trunk-release-open-pr.test.sh tests/jg-browser-reaper.test.sh \
    tests/jg-trunk-rollover.test.sh tests/jg-ship-local.test.sh 2>&1) || fail "a local list was refused: $local_sel"
  for s in jg-trunk-release-open-pr jg-browser-reaper jg-trunk-rollover; do
    case $(printf '%s\n' "$hosted" | grep -v 'not run on the hosted runner') in
      *"$s"*) fail "the hosted selection kept $s: $hosted" ;;
    esac
    assert_contains "$hosted" "not run on the hosted runner" 'a dropped script must be named'
    assert_contains "$local_sel" "tests/$s.test.sh" "the local selection must still list $s"
  done
  assert_contains "$hosted" 'tests/jg-ship-local.test.sh' 'a script with no listed need must stay selected'
  # A tool on the PATH keeps the script.
  printf '#!/bin/sh\n' >"$bin/bd"; chmod +x "$bin/bd"
  hosted=$(PATH=$bin /bin/bash "$RUNNER" --list --hosted tests/jg-browser-reaper.test.sh 2>&1) || fail "a hosted list was refused: $hosted"
  assert_contains "$hosted" 'tests/jg-browser-reaper.test.sh' 'a script whose tool is present must stay selected'
  pass 'the hosted selection drops scripts whose tool the runner lacks and the local selection keeps them'
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

test_the_hosted_selection_drops_scripts_that_hit_the_time_bound_or_have_no_hosted_time() {
  local dir out
  dir=$(mktemp -d "${TMPDIR:-/tmp}/jg-hosted-timings.XXXXXX")
  {
    printf '# <script>\t<exit>\t<duration_ms>, one hosted run per line, oldest first\n'
    # Ended at the bound once in five runs: dropped. Five runs under the bound: stays.
    printf 'tests/jg-teardown.test.sh\t0\t30000\n'
    printf 'tests/jg-teardown.test.sh\t124\t120000\n'
    printf 'tests/jg-teardown.test.sh\t0\t31000\n'
    printf 'tests/jg-teardown.test.sh\t0\t29000\n'
    printf 'tests/jg-teardown.test.sh\t0\t30500\n'
    local i
    for i in 1 2 3 4 5; do printf 'tests/jg-ship-local.test.sh\t0\t2%s000\n' "$i"; done
    # The 8 red release runs: the four scripts that hit the bound, as recorded.
    printf 'tests/jg-trunk.test.sh\t124\t120000\n'
    printf 'tests/jg-machine-call.test.sh\t124\t120000\n'
    printf 'tests/jg-bootstrap-backlog-reconcile.test.sh\t124\t120000\n'
    printf 'tests/jg-test-run.test.sh\t124\t132000\n'
  } >"$dir/timings.tsv"
  out=$(bash "$RUNNER" --list --hosted-timings "$dir/timings.tsv" \
    tests/jg-teardown.test.sh tests/jg-ship-local.test.sh tests/jg-trunk.test.sh tests/jg-machine-call.test.sh \
    tests/jg-bootstrap-backlog-reconcile.test.sh tests/jg-test-run.test.sh tests/jg-tmux.test.sh 2>&1) || fail "the hosted selection was refused: $out"
  assert_equals 'tests/jg-ship-local.test.sh' "$(printf '%s\n' "$out" | grep -v '^jg-test-run:')" 'only the script with five runs under the bound stays'
  local s
  for s in jg-teardown jg-trunk jg-machine-call jg-bootstrap-backlog-reconcile jg-test-run; do
    assert_contains "$out" "(ended at the time bound in its last five hosted runs): tests/$s.test.sh" "$s must be dropped and named"
  done
  assert_contains "$out" '(no hosted time): tests/jg-tmux.test.sh' 'a script with no hosted time must be dropped and named'
  out=$(bash "$RUNNER" --list tests/jg-teardown.test.sh tests/jg-trunk.test.sh 2>&1) || fail "the plain selection was refused: $out"
  assert_contains "$out" 'tests/jg-trunk.test.sh' 'without the flag a bound-ending script is still selected (it runs on our host)'
  rm -rf -- "$dir"
  pass 'the hosted selection drops scripts that hit the time bound in the last five runs or have no hosted time, and names them'
}

# within <seconds>, <path> exists (or, with <text>, contains it); otherwise the case fails naming <what>.
await_file() {  # <seconds> <path> <what> [<text>]
  local deadline=$((SECONDS + $1))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -z "${4:-}" ]; then [ ! -e "$2" ] || return 0; else ! grep -qF -- "$4" "$2" 2>/dev/null || return 0; fi
    sleep 0.2
  done
  fail "$3 within $1 s: $(cat "$2" 2>/dev/null)"
}

# Past machine_runs_max a run waits for a slot, naming the runner that holds it, and starts once that run ends. A run
# started inside an admitted run never waits on it, even one whose environment was cleared, as a landing gate clears it.
test_a_run_past_the_machine_limit_waits_for_a_slot() {
  local d=$TMP_ROOT/slots pid_a pid_b rc_a=0 rc_b=0
  mkdir -p "$d"
  printf 'machine_runs_max=1\n' >"$d/limits"
  write_script "$d/quick.test.sh" ''
  write_script "$d/second.test.sh" "touch '$d/b-started'"
  write_script "$d/hold.test.sh" "bash '$RUNNER' '$d/quick.test.sh' >'$d/nested.out' 2>&1 || exit 1
env -i PATH=\"\$PATH\" HOME=\"\$HOME\" JG_TEST_HOST_SLOTS='$d/slots' TEST_SPEED_LIMITS_FILE='$d/limits' \\
  bash '$RUNNER' '$d/quick.test.sh' >'$d/cleared.out' 2>&1 || exit 1
touch '$d/a-started'
i=0; while [ ! -e '$d/release' ] && [ \"\$i\" -lt 600 ]; do sleep 0.2; i=\$((i + 1)); done"
  env -u JG_TEST_RUN_SLOT -u JG_TRUNK_GATE_OUTPUT JG_TEST_HOST_SLOTS="$d/slots" TEST_SPEED_LIMITS_FILE="$d/limits" \
    bash "$RUNNER" "$d/hold.test.sh" >"$d/a.out" 2>&1 &
  pid_a=$!
  await_file 60 "$d/a-started" 'the first run, with a run inside it and one with a cleared environment, did not start'
  env -u JG_TEST_RUN_SLOT -u JG_TRUNK_GATE_OUTPUT JG_TEST_HOST_SLOTS="$d/slots" TEST_SPEED_LIMITS_FILE="$d/limits" \
    bash "$RUNNER" "$d/second.test.sh" >"$d/b.out" 2>&1 &
  pid_b=$!
  # A failed wait below still frees the first run: its script stops at release, or after 120 s.
  await_file 30 "$d/b.out" 'the second run did not say it waits for a slot' "waiting for a test-run slot: all 1 on this machine are in use (runner pids $pid_a)"
  [ ! -e "$d/b-started" ] || fail "the second run started while the only slot was held: $(cat "$d/b.out")"
  touch "$d/release"
  wait "$pid_a" || rc_a=$?
  wait "$pid_b" || rc_b=$?
  assert_equals 0 "$rc_a" "the run holding the slot must pass: $(cat "$d/a.out")"
  assert_equals 0 "$rc_b" "the queued run must pass once admitted: $(cat "$d/b.out")"
  [ -e "$d/b-started" ] || fail "the queued run never ran its script: $(cat "$d/b.out")"
  assert_not_contains "$(cat "$d/nested.out" "$d/cleared.out")" 'waiting for a test-run slot' 'a run inside an admitted run must not queue'
  pass 'a run past the machine limit waits for a slot and starts when it frees; runs inside an admitted run never wait'
}

# A run of the trunk itself (the lander's gate, the verify) names JG_TRUNK_GATE_OUTPUT. It owns one reserved slot that
# lane runs never take, so with every general slot held by lane proofs it starts at once; a second trunk run, with the
# reserved slot held, takes the first general slot that frees, ahead of lane runs that asked for a slot before it.
test_a_trunk_run_starts_at_once_and_takes_the_first_free_slot_ahead_of_lane_runs() {
  local d=$TMP_ROOT/trunkfirst name pid_a pid_b pid_c pid_t pid_u rc=0
  mkdir -p "$d"
  printf 'machine_runs_max=2\n' >"$d/limits"
  for name in a b c t u; do
    write_script "$d/$name.test.sh" "touch '$d/$name-started'
i=0; while [ ! -e '$d/$name-release' ] && [ \"\$i\" -lt 1200 ]; do sleep 0.2; i=\$((i + 1)); done"
  done
  run_in_slots() {  # <name> [<env assignment>...]: start <name>.test.sh as its own run
    local n=$1; shift
    env -u JG_TEST_RUN_SLOT -u JG_TRUNK_GATE_OUTPUT "$@" JG_TEST_HOST_SLOTS="$d/slots" TEST_SPEED_LIMITS_FILE="$d/limits" \
      bash "$RUNNER" "$d/$n.test.sh" >"$d/$n.out" 2>&1 &
  }
  run_in_slots a; pid_a=$!
  await_file 180 "$d/a-started" 'the first lane run did not start'
  run_in_slots b; pid_b=$!
  await_file 180 "$d/b-started" 'the second lane run did not start'
  run_in_slots c; pid_c=$!
  await_file 180 "$d/c.out" 'the third lane run did not say it waits for a slot' 'waiting for a test-run slot'
  # Every general slot is held by a lane run and a lane run is queued: the trunk run still starts at once.
  run_in_slots t JG_TRUNK_GATE_OUTPUT="$d/t.proof"; pid_t=$!
  await_file 180 "$d/t-started" 'the trunk run did not start at once on the reserved slot while all general slots were held'
  assert_not_contains "$(cat "$d/t.out")" 'waiting for a test-run slot' 'the trunk run must not queue behind lane runs'
  # A second trunk run finds the reserved slot held and waits for the first slot that frees.
  run_in_slots u JG_TRUNK_GATE_OUTPUT="$d/u.proof"; pid_u=$!
  await_file 180 "$d/u.out" 'the second trunk run did not say it waits for a slot' 'waiting for a test-run slot: all 3'
  # A failed wait below still frees every run: each script stops at its release file, or after 240 s.
  touch "$d/a-release"
  await_file 180 "$d/u-started" 'the second trunk run did not take the first general slot that freed'
  [ ! -e "$d/c-started" ] || fail "the lane run that asked first took the slot ahead of the trunk run: $(cat "$d/c.out")"
  touch "$d/t-release" "$d/u-release"
  await_file 180 "$d/c-started" 'the lane run did not start once the trunk run freed its slot'
  touch "$d/b-release" "$d/c-release"
  for pid in "$pid_a" "$pid_b" "$pid_c" "$pid_t" "$pid_u"; do wait "$pid" || rc=$?; done
  assert_equals 0 "$rc" "every run must pass: $(cat "$d"/*.out)"
  pass 'a trunk run starts at once on its reserved slot, and a second takes the first free slot ahead of lane runs'
}

# A test that moves HOME still builds Go from the caller's own build cache.
test_a_script_that_moves_home_keeps_the_callers_go_build_cache() {
  local d=$TMP_ROOT/gocache want out
  command -v go >/dev/null 2>&1 || { pass 'skip: no Go toolchain on PATH'; return 0; }
  want=$(env -u GOCACHE go env GOCACHE)
  mkdir -p "$d"
  write_script "$d/moves-home.test.sh" "HOME='$d/home' XDG_CACHE_HOME='$d/home/.cache'; echo \"cache=\$(go env GOCACHE)\""
  out=$(env -u GOCACHE bash "$RUNNER" "$d/moves-home.test.sh" 2>&1) || fail "the probe run failed: $out"
  assert_contains "$out" "cache=$want" 'a script that moves HOME must build from the caller Go build cache'
  pass 'a script that moves HOME keeps the caller Go build cache'
}

test_a_run_past_the_machine_limit_waits_for_a_slot
test_a_trunk_run_starts_at_once_and_takes_the_first_free_slot_ahead_of_lane_runs
test_a_script_that_moves_home_keeps_the_callers_go_build_cache
test_required_shards_keep_the_union_and_a_failed_shard
test_a_shard_that_stops_before_its_result_still_writes_a_failed_result
test_a_required_shard_over_its_budget_is_a_warning_and_runs_every_script
# select_fixture <dir>: a throwaway repo holding a copy of the runner, the shared
# file bin/jg-trunk.sh, a library that sources it, a script that only calls that
# library's caller, two core scripts, and five test scripts. The runner takes its
# root from its own location, so the copy selects against this repo alone.
select_fixture() {
  local d=$1
  mkdir -p "$d/bin" "$d/tests" "$d/core/trunk-landing" "$d/core/merge-on-green"
  cp "$RUNNER" "$ROOT/bin/jg-test-host-lib.sh" "$d/bin/"
  printf '#!/bin/sh\n' >"$d/bin/jg-trunk.sh"
  # shellcheck disable=SC2016
  printf '. "$(dirname "$0")/jg-trunk.sh"\n' >"$d/bin/jg-trunk-policy-lib.sh"
  printf '#!/bin/sh\njg-trunk-policy-lib.sh\n' >"$d/bin/jg-other.sh"
  printf '#!/bin/sh\n' >"$d/core/trunk-landing/trunk-landing.sh"
  printf '#!/bin/sh\n' >"$d/core/merge-on-green/merge-on-green.sh"
  printf 'echo ok jg-trunk.sh\n' >"$d/tests/jg-names-file.test.sh"
  printf 'echo ok jg-trunk-policy-lib.sh\n' >"$d/tests/jg-names-library.test.sh"
  printf 'echo ok trunk-landing.sh\n' >"$d/tests/jg-names-landing.test.sh"
  printf 'echo ok merge-on-green.sh\n' >"$d/tests/jg-names-merge.test.sh"
  printf 'echo ok jg-other.sh\n' >"$d/tests/jg-names-far-caller.test.sh"
  git -C "$d" init -q
  git -C "$d" -c user.email=t@t -c user.name=t add -A
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm base
}

test_a_changed_shared_file_selects_the_scripts_that_name_it() {
  local d=$TMP_ROOT/select-shared out
  select_fixture "$d"
  printf '# change\n' >>"$d/bin/jg-trunk.sh"
  out=$(cd "$d" && bash bin/jg-test-run.sh --list --changed --base HEAD 2>&1) || fail "a changed shared file was refused: $out"
  assert_contains "$out" 'tests/jg-names-file.test.sh' 'a script that names the file must be selected'
  assert_contains "$out" 'tests/jg-names-library.test.sh' 'a script that names a library sourcing the file must be selected'
  case $out in
    *jg-names-far-caller*|*jg-names-landing*|*jg-names-merge*) fail "a script that does not name the file or its library was selected: $out" ;;
  esac
  # The same planted failure is still found, in either kind of selected script.
  printf 'echo not ok jg-trunk.sh; exit 1\n' >"$d/tests/jg-names-file.test.sh"
  out=$(cd "$d" && bash bin/jg-test-run.sh --changed --base HEAD 2>&1) && fail "a failure in a script that names the file passed: $out"
  printf 'echo ok jg-trunk.sh\n' >"$d/tests/jg-names-file.test.sh"
  printf 'echo not ok jg-trunk-policy-lib.sh; exit 1\n' >"$d/tests/jg-names-library.test.sh"
  out=$(cd "$d" && bash bin/jg-test-run.sh --changed --base HEAD 2>&1) && fail "a failure in a script that names the library passed: $out"
  pass 'a changed shared file selects the scripts that name it and its libraries'
}

test_a_changed_core_script_selects_the_scripts_that_name_it() {
  local d=$TMP_ROOT/select-core out
  select_fixture "$d"
  printf '# change\n' >>"$d/core/trunk-landing/trunk-landing.sh"
  out=$(cd "$d" && bash bin/jg-test-run.sh --list --changed --base HEAD 2>&1) || fail "a changed core script was refused: $out"
  assert_contains "$out" 'tests/jg-names-landing.test.sh' 'a script that names the landing check must be selected'
  case $out in
    *jg-names-merge*|*jg-names-file*) fail "a script that does not name the landing check was selected: $out" ;;
  esac
  git -C "$d" -c user.email=t@t -c user.name=t commit -qam change
  printf '# change\n' >>"$d/core/merge-on-green/merge-on-green.sh"
  out=$(cd "$d" && bash bin/jg-test-run.sh --list --changed --base HEAD 2>&1) || fail "a changed core script was refused: $out"
  assert_contains "$out" 'tests/jg-names-merge.test.sh' 'a script that names the merge check must be selected'
  pass 'a changed core script selects the scripts that name it'
}

test_a_changed_fleet_homes_library_selects_the_move_test() {
  local d=$TMP_ROOT/select-homes out
  select_fixture "$d"
  # The library is sourced by bin/jg-update.sh and bin/jg-trunk-live-lag.sh, which no test of it names; the one test
  # that drives both callers against real homes owns it, and no other script is selected.
  printf '#!/bin/sh\n' >"$d/bin/jg-fleet-homes-lib.sh"
  printf 'echo ok jg-update.sh\n' >"$d/tests/jg-update-local-base.test.sh"
  git -C "$d" -c user.email=t@t -c user.name=t add -A
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm homes
  printf '# change\n' >>"$d/bin/jg-fleet-homes-lib.sh"
  out=$(cd "$d" && bash bin/jg-test-run.sh --list --changed --base HEAD 2>&1) || fail "a changed fleet-homes library was refused: $out"
  assert_contains "$out" 'tests/jg-update-local-base.test.sh' 'the test that moves every home must be selected'
  case $out in
    *jg-names-*) fail "a script that does not exercise the library was selected: $out" ;;
  esac
  pass 'a changed fleet-homes library selects the fleet move test'
}

test_a_changed_dispatch_skill_runs_the_floor_test() {
  local d=$TMP_ROOT/select-dispatch out
  select_fixture "$d"
  cp "$ROOT/bin/jg-timeout-lib.sh" "$d/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$d/tests/"
  mkdir -p "$d/.agents/skills/task-dispatch"
  printf 'original\n' >"$d/.agents/skills/task-dispatch/SKILL.md"
  printf 'echo floor failure; exit 1\n' >"$d/tests/jg-agents-md-floor.test.sh"
  git -C "$d" add .agents tests
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm dispatch
  printf 'changed\n' >>"$d/.agents/skills/task-dispatch/SKILL.md"
  out=$(cd "$d" && bash bin/jg-test-run.sh --list --changed --base HEAD 2>&1) || fail "dispatch selection refused: $out"
  assert_contains "$out" 'tests/jg-agents-md-floor.test.sh' 'a dispatch change must select the floor test'
  out=$(cd "$d" && bash bin/jg-test-run.sh --changed --base HEAD 2>&1) && fail "a failing floor test passed the gate: $out"
  assert_contains "$out" 'floor failure' 'the selected floor failure must be reported'
  pass 'a dispatch skill change runs the floor test and rejects its failure'
}

# A time budget advises and never stops: a tree whose largest serial shard packs 3 s over its target still passes,
# with the advise line and a warning, while a script that no shard runs still refuses.
test_the_coverage_time_budget_advises_and_a_script_no_shard_runs_still_refuses() {
  local fixture=$TMP_ROOT/coverage out rc=0 max
  mkdir -p "$fixture"
  cp -R "$ROOT/bin" "$ROOT/defaults" "$ROOT/tests" "$fixture/"
  max=$(bash "$fixture/bin/jg-test-run.sh" --check-coverage 2>&1 | sed -n 's/.* serial_max_ms=\([0-9]*\) .*/\1/p')
  [ -n "$max" ] || fail "the untouched tree must print its coverage line"
  sed -i "s/^PORTABLE_SERIAL_MAX_WEIGHT_MS=.*/PORTABLE_SERIAL_MAX_WEIGHT_MS=$((max - 3000))/" "$fixture/bin/jg-test-run.sh"
  out=$(bash "$fixture/bin/jg-test-run.sh" --check-coverage 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "a shard 3 s over its target must pass: rc=$rc $out"
  assert_contains "$out" 'JG_TEST_COVERAGE advise ' 'the advise line must be printed'
  assert_contains "$out" 'coverage advice: largest portable serial shard' 'the warning must name the shard'
  sed -i '/^tests\/jg-x-mode.test.sh$/d' "$fixture/bin/jg-test-run.sh"
  rc=0
  out=$(bash "$fixture/bin/jg-test-run.sh" --check-coverage 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "a script no shard runs must still refuse: rc=$rc $out"
  assert_contains "$out" 'tests/jg-x-mode.test.sh' 'the refusal must name the script'
  pass 'the coverage time budget advises with exit 0 and a script no shard runs still refuses'
}

test_shards_split_a_selection_without_losing_or_repeating_a_script
test_the_e2e_limit_is_60_seconds_in_config
test_an_e2e_test_over_its_limit_warns_naming_itself_and_its_time
test_the_unit_limit_is_5_seconds_in_config
test_a_unit_test_over_its_limit_warns_naming_itself_and_its_time
test_the_gate_wall_limit_is_10_minutes_in_config
test_a_run_past_the_gate_budget_fails_without_starting_the_next_test
test_a_wall_failure_with_no_functional_failure_stays_red_in_aggregate
test_a_hanging_test_is_killed_and_reported_instead_of_holding_the_run
test_a_slow_passing_script_past_the_per_script_bound_warns_and_passes
test_a_slow_failing_script_past_the_per_script_bound_stays_red
test_the_gate_stops_a_hung_script_with_its_children_and_temp_folder_without_a_flag
test_a_test_within_its_limits_is_unaffected
test_a_weight_cap_defers_slow_suites_and_names_them
test_the_hosted_selection_drops_scripts_that_hit_the_time_bound_or_have_no_hosted_time
test_the_hosted_selection_drops_scripts_whose_tool_the_runner_lacks
test_a_deleted_journey_does_not_refuse_the_changed_selection
test_a_changed_shared_file_selects_the_scripts_that_name_it
test_a_changed_core_script_selects_the_scripts_that_name_it
test_a_changed_fleet_homes_library_selects_the_move_test
test_a_changed_dispatch_skill_runs_the_floor_test
test_the_coverage_time_budget_advises_and_a_script_no_shard_runs_still_refuses
test_a_quarantined_script_is_listed_not_run_and_the_gate_passes

printf 'all %s\n' 'jg-test-run limit tests passed'
