#!/usr/bin/env bash
# A skip in tests/lib.sh exits JG_TEST_SKIP_EXIT when a caller sets it (77), so a caller that runs a test
# script directly can tell a skip from a pass; unset, a skip exits 0 as it always did and the runner still
# counts it as skipped_gate. Each case runs a real fixture test that sources the real lib.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/jg-test-run.sh"
TMP_ROOT=$(jg_test_tmproot jg-test-run-skip)
export JG_TEST_HOST_SLOTS="$TMP_ROOT/run-slots"

# write_fixture <name> <shell-body>: a test script that sources the real lib.sh, then runs <shell-body>.
write_fixture() {
  printf '#!/usr/bin/env bash\nset -u\n. "%s/tests/lib.sh"\n%s\n' "$ROOT" "$2" >"$TMP_ROOT/$1"
  chmod +x "$TMP_ROOT/$1"
}

# run_fixture <name> [<skip-exit>]: the fixture's exit code, with no live opt-in in its environment.
run_fixture() {
  local rc=0
  if [ -n "${2:-}" ]; then
    env -u JG_FX_LIVE JG_TEST_SKIP_EXIT="$2" bash "$TMP_ROOT/$1" >/dev/null 2>&1 || rc=$?
  else
    env -u JG_FX_LIVE -u JG_TEST_SKIP_EXIT bash "$TMP_ROOT/$1" >/dev/null 2>&1 || rc=$?
  fi
  printf '%s' "$rc"
}

# shellcheck disable=SC2016 # the bodies run in the fixture script, not here
write_fixture gate-skip.test.sh 'JG_LIVE=0 jg_live_gate default-on JG_FX_LIVE
printf "not ok - reached past the skip\n"; exit 1'
write_fixture usr1-skip.test.sh 'kill -s USR1 "$$"; sleep 1; printf "not ok - trap did not end the suite\n"; exit 1'
write_fixture passing.test.sh 'printf "ok - fixture passes\n"; exit 0'

test_a_gate_skip_exits_zero_by_default() {
  local rc
  rc=$(run_fixture gate-skip.test.sh)
  [ "$rc" = 0 ] || fail "a gate skip without JG_TEST_SKIP_EXIT must exit 0, got $rc"
  pass 'a gate skip exits 0 when JG_TEST_SKIP_EXIT is unset'
}

test_a_gate_skip_exits_77_when_asked() {
  local rc
  rc=$(run_fixture gate-skip.test.sh 77)
  [ "$rc" = 77 ] || fail "a gate skip with JG_TEST_SKIP_EXIT=77 must exit 77, got $rc"
  pass 'a gate skip exits 77 when JG_TEST_SKIP_EXIT=77'
}

test_the_usr1_skip_path_follows_the_variable() {
  local rc
  rc=$(run_fixture usr1-skip.test.sh 77)
  [ "$rc" = 77 ] || fail "the USR1 skip with JG_TEST_SKIP_EXIT=77 must exit 77, got $rc"
  rc=$(run_fixture usr1-skip.test.sh)
  [ "$rc" = 0 ] || fail "the USR1 skip without JG_TEST_SKIP_EXIT must exit 0, got $rc"
  pass 'the USR1 skip exits 77 with the variable and 0 without it'
}

test_a_passing_fixture_is_never_77() {
  local rc
  rc=$(run_fixture passing.test.sh 77)
  [ "$rc" = 0 ] || fail "a passing fixture must exit 0 even with JG_TEST_SKIP_EXIT=77, got $rc"
  pass 'a passing fixture exits 0 with JG_TEST_SKIP_EXIT=77'
}

test_the_runner_still_counts_a_skip_as_skipped_gate() {
  local out rc=0
  out=$(env -u JG_FX_LIVE -u JG_TEST_SKIP_EXIT bash "$RUNNER" "$TMP_ROOT/gate-skip.test.sh" 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "the runner must exit 0 on a skip, got $rc: $out"
  printf '%s\n' "$out" | grep -qE '^JG_TEST_SUMMARY total=1 failed=0 skipped_gate=1( |$)' \
    || fail "the runner must count the skip as skipped_gate=1: $out"
  pass 'the runner counts a skip as skipped_gate=1 and exits 0'
}

test_a_gate_skip_exits_zero_by_default
test_a_gate_skip_exits_77_when_asked
test_the_usr1_skip_path_follows_the_variable
test_a_passing_fixture_is_never_77
test_the_runner_still_counts_a_skip_as_skipped_gate

printf 'all %s\n' 'jg-test-run-skip tests passed'
