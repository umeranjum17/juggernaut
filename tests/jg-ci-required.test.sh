#!/usr/bin/env bash
# `CI required` is the one status check a pull request merges on, so its verdict
# must follow the lane set the event owes exactly: a pull request owes only the
# fast set (changed-file lint and changed-file tests), a push to main or a
# release branch owes the full set, every lane this change needed ran and
# passed, a skipped lane on a behavior change refuses, and a documentation
# change is allowed to skip the lanes it does not need.
# The heavy behaviour suite is not a lane in either set, so a verdict must never
# wait on it.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REQUIRED="$ROOT/bin/jg-ci-required.sh"

# verdict <event> <behavior> <needs-json>: run the gate and keep its output and status.
verdict() {  # <event> <behavior> <needs json>
  local event=$1 behavior=$2 needs=$3
  OUT=$(JG_CI_BUS="${AREA_BUS-false}" JG_CI_SHELL="${AREA_SHELL-false}" JG_CI_EVALS="${AREA_EVALS-false}" \
    JG_CI_EVENT="$event" JG_CI_NEEDS="$needs" JG_CI_BEHAVIOR="$behavior" bash "$REQUIRED" 2>&1)
  RC=$?
}

# expect_verdict <want rc> <event> <behavior> <needs-json> <label>
expect_verdict() {  # <want rc> <event> <behavior> <needs json> <label>
  local want=$1 label=$5
  verdict "$2" "$3" "$4"
  [ "$RC" -eq "$want" ] || fail "$label: expected exit $want, got $RC: $OUT"
}

# fast_lanes <result>: the pull request set, every behavior lane at <result>.
# The scope verdict itself always passed here, because a skipped invariants job
# is what CI looks like when nothing reported at all.
fast_lanes() {  # <result>
  printf '{"invariants":{"result":"success"},"lint":{"result":"%s"},"tests":{"result":"%s"}}' \
    "$1" "$1"
}

# full_lanes <result>: the post-merge set, every behavior lane at <result>.
full_lanes() {  # <result>
  printf '{"invariants":{"result":"success"},"lint":{"result":"%s"},"syntax":{"result":"%s"},"smoke":{"result":"%s"},"evals":{"result":"%s"},"bus":{"result":"%s"}}' \
    "$1" "$1" "$1" "$1" "$1"
}

test_a_passing_fast_set_verifies_a_pull_request() {
  expect_verdict 0 pull_request true "$(fast_lanes success)" \
    'a passed fast set must verify a pull request'
  assert_contains "$OUT" 'verified: every job this behavior change needed ran and passed' \
    'the verdict must say which kind of change it verified'
  pass 'a passing fast set verifies a pull request'
}

test_a_pull_request_does_not_wait_for_a_post_merge_lane() {
  # A pull request never runs syntax, smoke, evals or bus, so their absence from
  # the needed set is not a refusal: that is the whole point of the fast set.
  expect_verdict 0 pull_request true "$(fast_lanes success)" \
    'a post-merge lane must not be owed by a pull request'
  pass 'a pull request does not wait for a post-merge lane'
}

test_a_push_owes_the_full_set() {
  expect_verdict 0 push true "$(full_lanes success)" 'a passed full set must verify a push'
  expect_verdict 1 push true "$(fast_lanes success)" \
    'a push missing the post-merge lanes must refuse'
  assert_contains "$OUT" 'syntax=missing' 'the refusal must name the lane the push owed'
  pass 'a push owes the full set'
}

test_an_absent_event_owes_the_full_set() {
  expect_verdict 0 '' true "$(full_lanes success)" 'an absent event must take the slower verdict'
  expect_verdict 1 '' true "$(fast_lanes success)" \
    'an absent event must not be read as the fast pull request set'
  pass 'an absent event owes the full set'
}

test_a_skipped_lane_on_a_behavior_change_refuses() {
  expect_verdict 1 pull_request true '{"invariants":{"result":"success"},"lint":{"result":"success"},"tests":{"result":"skipped"}}' \
    'a skipped lane on a behavior change must refuse'
  assert_contains "$OUT" 'tests=skipped' 'the refusal must name the lane that did not run'
  pass 'a skipped lane on a behavior change refuses'
}

test_a_documentation_change_may_skip_the_behavior_lanes() {
  expect_verdict 0 pull_request false "$(fast_lanes skipped)" \
    'a documentation change must verify with the lanes skipped'
  assert_contains "$OUT" 'documentation change' \
    'the verdict must say it verified a documentation change'
  pass 'a documentation change may skip the behavior lanes'
}

test_a_failed_lane_refuses_even_on_a_documentation_change() {
  expect_verdict 1 pull_request false '{"invariants":{"result":"success"},"lint":{"result":"failure"},"tests":{"result":"skipped"}}' \
    'a failed lane must refuse whatever the scope says'
  assert_contains "$OUT" 'lint=failure' 'the refusal must name the failed lane'
  pass 'a failed lane refuses even on a documentation change'
}

test_an_unreadable_scope_refuses() {
  expect_verdict 1 pull_request '' "$(fast_lanes success)" \
    'an unknown scope verdict must refuse'
  assert_contains "$OUT" 'cannot say which lanes this change needed' \
    'the refusal must say the scope verdict was unreadable'
  pass 'an unreadable scope refuses'
}

# A pull request that touches an area owes that area's suite; an untouched area may skip.
test_a_touched_area_suite_must_run_on_a_pull_request() {
  local needs='{"invariants":{"result":"success"},"lint":{"result":"success"},"tests":{"result":"success"},"bus":{"result":"skipped"},"syntax":{"result":"success"},"smoke":{"result":"success"},"evals":{"result":"success"}}'
  AREA_BUS=true AREA_SHELL=true AREA_EVALS=true expect_verdict 1 pull_request true "$needs" \
    'a skipped suite for a touched area must refuse'
  assert_contains "$OUT" 'bus=skipped' 'the refusal must name the skipped area suite'
  AREA_BUS=true AREA_SHELL=true AREA_EVALS=true expect_verdict 1 pull_request true "$(fast_lanes success)" \
    'an area suite that did not report must refuse'
  assert_contains "$OUT" 'bus=missing' 'the refusal must name the missing area suite'
  AREA_BUS=false AREA_SHELL=true AREA_EVALS=true expect_verdict 0 pull_request true "$needs" \
    'a skipped suite for an untouched area must pass'
  AREA_BUS=false AREA_SHELL=false AREA_EVALS=false expect_verdict 1 pull_request true \
    '{"invariants":{"result":"success"},"lint":{"result":"success"},"tests":{"result":"success"},"bus":{"result":"failure"}}' \
    'a failed area suite must refuse even when the area is untouched'
  pass 'a touched area suite must run on a pull request'
}

test_a_touched_area_suite_must_run_on_a_pull_request
test_a_passing_fast_set_verifies_a_pull_request
test_a_pull_request_does_not_wait_for_a_post_merge_lane
test_a_push_owes_the_full_set
test_an_absent_event_owes_the_full_set
test_a_skipped_lane_on_a_behavior_change_refuses
test_a_documentation_change_may_skip_the_behavior_lanes
test_a_failed_lane_refuses_even_on_a_documentation_change
test_an_unreadable_scope_refuses
printf 'jg-ci-required: ok\n'
