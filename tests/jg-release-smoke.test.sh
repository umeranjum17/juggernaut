#!/usr/bin/env bash
# tests/jg-release-smoke.test.sh - the release smoke (bin/jg-release-smoke.sh).
#
# The rules under test: the three lanes pass on the current merge path and the
# last line reports PASS with the lane count; a run that has no time left fails
# with exit 1 and a FAIL line instead of passing or hanging; and the scratch
# directory is removed afterwards.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SMOKE=$ROOT/bin/jg-release-smoke.sh
TMP_ROOT=$(jg_test_tmproot jg-release-smoke-tests)

test_all_lanes_pass_and_clean_up() {
  local out rc=0
  out=$(TMPDIR=$TMP_ROOT bash "$SMOKE" 2>&1) || rc=$?
  assert_equals "0" "$rc" "the release smoke failed: $out"
  case "$out" in *"release smoke: PASS lanes=3 "*) ;; *) fail "no PASS line with three lanes: $out" ;; esac
  assert_equals "0" "$(find "$TMP_ROOT" -maxdepth 1 -name 'jg-release-smoke.*' | wc -l | tr -d ' ')" "the scratch directory was left behind"
  pass "all three lanes pass and the scratch directory is removed"
}

test_a_run_over_its_budget_fails() {
  local out rc=0
  out=$(TMPDIR=$TMP_ROOT bash "$SMOKE" --budget 1 2>&1) || rc=$?
  assert_equals "1" "$rc" "an over-budget run did not exit 1: $out"
  case "$out" in *"release smoke: FAIL"*) ;; *) fail "no FAIL line for an over-budget run: $out" ;; esac
  pass "a run over its budget fails with a FAIL line"
}

test_all_lanes_pass_and_clean_up
test_a_run_over_its_budget_fails
