#!/usr/bin/env bash
# Integration test for ending a hung landing through the landing check's own path (bin/jg-trunk.sh cancel, core/trunk-landing/cancel.sh),
# through the real check and the real landing over real git repositories (tests/jg-trunk-fixture.sh). The gate is `sleep 300`.
#
# C1 A landing run whose gate hangs is cancelled by name: its process group is gone, its running state and every lock it held are
#    cleared, why is recorded, and the next ready lane starts by itself (no raw kill).
# C2 A stack (runbatch) is ended by naming any one of its lanes: every lane of the stack is released.
# C3 A cancel with no running landing refuses with the exact reason, a worker is refused, and a reason is required.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"
# shellcheck disable=SC2034 # read by the fixture
JG_TRUNK_FIXTURE_CACHE=1

hang_world() {  # <name> [<extra policy line>]
  world "$1"
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  printf 'gate-full=sleep 300\ngate-slots=1\n%s\n' "${2-}" >> "$HOME_D/config/trunk-policy"
}
kick() { JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" || fail "the check must not fail"; }
mem() { printf '%s\n' "$HOME_D/data/jg-trunk-landing"; }
run_pid() {  # <id>: the pid the lane's running state publishes
  local f; for f in "$(mem)/$1".*.state; do [ -f "$f" ] && awk '$1 == "running" && $3 != "" { print $3 }' "$f"; done
}
wait_for() {  # <what> <command...>
  local what=$1 _; shift
  for _ in $(seq 1 200); do "$@" && return 0; sleep 0.1; done
  fail "never reached: $what"
}
has_pid() { [ -n "$(run_pid "$1")" ]; }
gating() { [ -n "$(ls "$HOME_D"/state/.trunk-gate-proj-*.lock 2>/dev/null)" ]; }
cancel() { trunk cancel "$@"; }

test_a_hung_landing_is_cancelled_and_the_next_lane_starts() {
  local pid out rc=0 base
  hang_world hung; base=$(tip)
  lane h1 one h1.txt; kick >/dev/null; wait_for 'the first landing publishes its pid' has_pid h1; wait_for 'its gate runs' gating
  pid=$(run_pid h1)
  [ "$(ps -o pgid= -p "$pid" | tr -d ' ')" = "$pid" ] || fail "the landing run leads its own process group"
  lane h2 two h2.txt; kick >/dev/null
  [ -z "$(run_pid h2)" ] || fail "the second lane waits while the first gates (gate-slots=1)"
  ls "$HOME_D"/state/.trunk-run-h1-*.lock "$HOME_D"/state/.landing-h1-*.lock >/dev/null 2>&1 || fail "the running landing holds its locks"
  out=$(cancel h1 --reason 'the gate hangs' 2>&1) || fail "cancel must end the run: $out"
  assert_contains "$out" "cancelled the landing run of h1" "cancel names what it ended"
  ! kill -0 "$pid" 2>/dev/null || fail "the landing run $pid is still alive"
  ! pgrep -g "$pid" >/dev/null 2>&1 || fail "a child of the landing run is still alive: $(pgrep -g "$pid" -a)"
  ! grep -qs '^running' "$(mem)"/h1.*.state || fail "the cancelled lane still shows running: $(cat "$(mem)"/h1.*.state)"
  grep -qs '^wait cancelled by Overwatch: the gate hangs' "$(mem)"/h1.*.state || fail "the lane waits, with why: $(cat "$(mem)"/h1.*.state)"
  ! ls "$HOME_D"/state/.trunk-run-h1-*.lock "$HOME_D"/state/.landing-h1-*.lock "$HOME_D"/state/.control-h1.lock "$HOME_D"/state/.trunk-gate-proj-*.lock \
    "$HOME_D"/state/.trunk-front-proj.lock "$HOME_D"/state/.trunk-proj.lock >/dev/null 2>&1 || fail "a lock of the cancelled run is still there: $(ls -d "$HOME_D"/state/.*.lock)"
  [ ! -e "$HOME_D/state/trunk-front-proj" ] || fail "the front record of the cancelled run is cleared"
  grep -q "h1.*the gate hangs" "$(mem)/cancelled.tsv" || fail "why is recorded: $(cat "$(mem)/cancelled.tsv" 2>/dev/null)"
  grep -q 'cancelled the landing run of h1.*the gate hangs' "$(mem)/outbox" || fail "Overwatch is told through the outbox"
  wait_for 'the next ready lane starts' has_pid h2
  [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = 0 ] || fail "a cancelled landing moves nothing"
  [ "$(git -C "$PROJ" rev-parse fm/h1)" = "$(git -C "$W/lanes/h1" rev-parse HEAD)" ] || fail "the cancelled lane keeps its commit"
  pass 'a hung landing is ended by its own cancel: group gone, state and locks cleared, why recorded, the next lane starts'
}

test_a_stack_is_ended_by_naming_one_lane() {
  local pid out
  hang_world stack 'flush-at-ready=2'
  lane s1 one s1.txt; lane s2 two s2.txt; kick >/dev/null
  wait_for 'the stack publishes its pid' has_pid s1; pid=$(run_pid s1)
  [ "$(run_pid s2)" = "$pid" ] || fail "both lanes of the stack share one run: $(cat "$(mem)"/s*.state)"
  out=$(cancel s2 --reason 'duplicate stack' 2>&1) || fail "cancel must end the stack: $out"
  assert_contains "$out" "s2, s1" "both lanes of the stack are named"
  ! kill -0 "$pid" 2>/dev/null || fail "the stack run $pid is still alive"
  ! grep -qs '^running' "$(mem)"/s*.state || fail "a lane of the stack still shows running: $(cat "$(mem)"/s*.state)"
  ! ls "$HOME_D"/state/.trunk-run-s*.lock >/dev/null 2>&1 || fail "a run lock of the stack is still there"
  pass 'a stack run is ended by naming one of its lanes and every lane is released'
}

test_cancel_refuses_what_it_cannot_do() {
  local out rc=0
  hang_world refuse; lane r1 one r1.txt
  out=$(cancel r1 --reason x 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a cancel with no running landing must refuse"
  assert_contains "$out" "no landing is running for r1" "the refusal says why"
  out=$(cancel r1 2>&1) || rc=$?
  assert_contains "$out" "usage: jg-trunk.sh cancel" "a reason is required"
  out=$(JG_TASK_ID=r1 cancel r1 --reason x 2>&1) || rc=$?
  assert_contains "$out" "a worker never cancels a landing" "a worker is refused"
  pass 'a cancel with nothing running, no reason, or from a worker refuses with its reason'
}

test_a_hung_landing_is_cancelled_and_the_next_lane_starts
test_a_stack_is_ended_by_naming_one_lane
test_cancel_refuses_what_it_cannot_do
printf 'jg-trunk-cancel: ok\n'
