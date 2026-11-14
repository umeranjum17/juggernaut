#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh `land-batch`: a batch never fails twice on the same red (H29a).
# Through tests/jg-trunk-fixture.sh it runs the real lander with the real gate chain over real git repositories.
#
# T1 A stack that went red is not gated again on the same tip: the same two lanes, reported ready again with the same commits, are halved
#    at once. No gate runs, both are returned, each with the failing script and its test name.
# T2 A different set of lanes is a new question and is gated; a red the host caused (a retry-class refusal) is never written down.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"
# shellcheck disable=SC2034 # read by the fixture
JG_TRUNK_FIXTURE_CACHE=1

# shellcheck disable=SC2016 # the gate body is written out verbatim and expands when the gate runs it
repeat_world() {  # <name>
  world "$1"; rig
  printf 'gate-full=echo run >> "%s/gate-runs"; bash %s/rig.sh --all\n' "$W" "$W" >> "$HOME_D/config/trunk-policy"
}
runs() { [ -f "$W/gate-runs" ] && grep -c . "$W/gate-runs" || echo 0; }

test_a_stack_that_went_red_is_halved_at_once_the_second_time() {
  local base out again n
  repeat_world again; base=$(tip)
  lane r1 'echo "not ok 7 - r1 breaks the parser" >&2; exit 1' t/r1.test.sh; lane r2 'echo "not ok 3 - r2 breaks the writer" >&2; exit 1' t/r2.test.sh
  out=$(trunk land-batch r1 r2 2>&1) || fail "a red stack returns its lanes, it does not fail: $out"
  assert_contains "$out" "returned r1: REFUSED: this lane is the red in its batch" "the first run returns the first red lane"
  assert_contains "$out" "returned r2: REFUSED: this lane is the red in its batch" "the first run returns the second red lane"
  n=$(runs); [ "$n" -gt 0 ] || fail "the first run must gate the stack"
  [ "$(tip)" = "$base" ] || fail "no red lane may land"
  ready r1; ready r2
  again=$(trunk land-batch r1 r2 2>&1) || fail "the repeat returns its lanes, it does not fail: $again"
  [ "$(runs)" = "$n" ] || fail "the same red stack must not run a gate again: $n gates, then $(runs)"
  assert_contains "$again" "went red before on this tip; not gated again" "the repeat says why it ran nothing"
  assert_contains "$again" "returned r1: REFUSED: this lane is the red in its batch" "the repeat returns the first lane"
  assert_contains "$again" "returned r2: REFUSED: this lane is the red in its batch" "the repeat returns the second lane"
  assert_contains "$again" "t/r1.test.sh: not ok - r1 breaks the parser" "a lane red alone is returned with its script and test name, without the test number"
  assert_contains "$again" "t/r2.test.sh: not ok - r2 breaks the writer" "the other lane is returned with its own script and test"
  [ "$(tip)" = "$base" ] || fail "the repeat moved the trunk"
  pass 'a stack that went red is halved at once the second time: no gate runs, each lane returned with its script and test'
}

test_another_set_of_lanes_is_a_new_question() {
  local base out n
  repeat_world newset; base=$(tip)
  lane s1 'echo "not ok 1 - s1 breaks" >&2; exit 1' t/s1.test.sh; lane s2 'exit 0' t/s2.test.sh; lane s3 'exit 0' t/s3.test.sh
  trunk land-batch s1 s2 >/dev/null 2>&1 || fail "the first batch must return its red lane"
  n=$(runs); [ "$(tip)" != "$base" ] || fail "the green lane lands"
  ready s1
  out=$(trunk land-batch s1 s3 2>&1) || fail "the second batch must finish: $out"
  [ "$(runs)" -gt "$n" ] || fail "a set with another lane is gated: $n gates, then $(runs)"
  case $out in *"not gated again"*) fail "a new set was taken for a known one: $out" ;; esac
  assert_contains "$out" "landed s3" "the green lane of the new set lands"
  pass 'another set of lanes, on a moved tip, is a new question and is gated'
}

test_a_stack_that_went_red_is_halved_at_once_the_second_time
test_another_set_of_lanes_is_a_new_question
