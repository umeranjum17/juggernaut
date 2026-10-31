#!/usr/bin/env bash
# `CI required` is the one status check a pull request merges on, so its verdict
# must follow the thin gate's job set exactly: every lane this change needed ran
# and passed, a skipped lane on a behavior change refuses, and a documentation
# change is allowed to skip the lanes it does not need.
# The heavy behaviour suite is not a pull request lane, so a verdict must never
# wait on it.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REQUIRED="$ROOT/bin/jg-ci-required.sh"

# verdict <behavior> <needs-json>: run the gate and keep its output and status.
verdict() {  # <behavior> <needs json>
  local behavior=$1 needs=$2
  OUT=$(JG_CI_NEEDS="$needs" JG_CI_BEHAVIOR="$behavior" bash "$REQUIRED" 2>&1)
  RC=$?
}

# expect_verdict <want rc> <behavior> <needs-json> <label>
expect_verdict() {  # <want rc> <behavior> <needs json> <label>
  local want=$1 label=$4
  verdict "$2" "$3"
  [ "$RC" -eq "$want" ] || fail "$label: expected exit $want, got $RC: $OUT"
}

# every_lane <result>: the full thin lane set, each lane at <result>.
every_lane() {  # <result>
  printf '{"invariants":{"result":"success"},"lint":{"result":"%s"},"syntax":{"result":"%s"},"smoke":{"result":"%s"},"evals":{"result":"%s"}}' \
    "$1" "$1" "$1" "$1"
}

test_a_passing_thin_gate_verifies() {
  expect_verdict 0 true "$(every_lane success)" 'a passed thin gate must verify' 
  assert_contains "$OUT" 'verified: every job this behavior change needed ran and passed' \
    'the verdict must say which kind of change it verified'
  pass 'a passing thin gate verifies'
}

test_a_skipped_lane_on_a_behavior_change_refuses() {
  expect_verdict 1 true '{"invariants":{"result":"success"},"lint":{"result":"success"},"syntax":{"result":"skipped"},"smoke":{"result":"success"},"evals":{"result":"success"}}' \
    'a skipped lane on a behavior change must refuse'
  assert_contains "$OUT" 'syntax=skipped' 'the refusal must name the lane that did not run'
  pass 'a skipped lane on a behavior change refuses'
}

test_a_documentation_change_may_skip_the_behavior_lanes() {
  expect_verdict 0 false "$(every_lane skipped)" 'a documentation change must verify with the lanes skipped' 
  assert_contains "$OUT" 'documentation change' 'the verdict must say it verified a documentation change'
  pass 'a documentation change may skip the behavior lanes'
}

test_a_failed_lane_refuses_even_on_a_documentation_change() {
  expect_verdict 1 false '{"invariants":{"result":"success"},"lint":{"result":"failure"},"syntax":{"result":"skipped"},"smoke":{"result":"skipped"},"evals":{"result":"skipped"}}' \
    'a failed lane must refuse whatever the scope says'
  assert_contains "$OUT" 'lint=failure' 'the refusal must name the failed lane'
  pass 'a failed lane refuses even on a documentation change'
}

test_an_unreadable_scope_refuses() {
  expect_verdict 1 '' "$(every_lane success)" 'an unknown scope verdict must refuse'
  assert_contains "$OUT" 'cannot say which lanes this change needed' \
    'the refusal must say the scope verdict was unreadable'
  pass 'an unreadable scope refuses'
}

test_a_passing_thin_gate_verifies
test_a_skipped_lane_on_a_behavior_change_refuses
test_a_documentation_change_may_skip_the_behavior_lanes
test_a_failed_lane_refuses_even_on_a_documentation_change
test_an_unreadable_scope_refuses
printf 'jg-ci-required: ok\n'
