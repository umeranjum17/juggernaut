#!/usr/bin/env bash
# Integration test for two landing gates at once (core/trunk-landing/trunk-landing.sh, bin/jg-trunk.sh `land`), through the real
# check and the real gate chain over real git repositories (tests/jg-trunk-fixture.sh). The gate is a stand-in that takes 2 seconds
# and logs its start and end, so each case reads overlap and order from the log, never from a wall clock.
#
# G1 A lane that is ready while the first one gates starts at once, is gated on top of the first one's commit, and both land in order
#    after one gate each (the second started before the first ended). A third lane waits: at most 2 gates at once, then it lands too.
# G2 When the first lane is red, the second lands after one more gate (3 gate runs): it is gated again on the tip, the first is returned.
# G3 With gate-slots=1 the second lane waits for the first one's end: no overlap, and both still land.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"
# shellcheck disable=SC2034 # read by the fixture
JG_TRUNK_FIXTURE_CACHE=1

# The stand-in gate logs its start and end. While $W/hold exists the first gate to start stays open until $W/release exists, so the
# case controls when the first gate ends and the overlap does not depend on how loaded the host is.
# shellcheck disable=SC2016 # the gate body is written out verbatim and expands when the gate runs it
slow_world() {  # <name> [<extra policy line>]
  world "$1"
  ln -s "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  cat > "$W/slow-gate.sh" <<SH
#!/usr/bin/env bash
printf 'start %s\n' "\$(date +%s.%N)" >> "$W/gate-runs"
if [ -f "$W/hold" ] && [ "\$(grep -c '^start' "$W/gate-runs")" = 1 ]; then
  for _ in \$(seq 1 300); do [ -f "$W/release" ] && break; sleep 0.1; done
else sleep 1; fi
rc=0; ! grep -rq BAD --include='*.txt' . || rc=1
printf 'end %s\n' "\$(date +%s.%N)" >> "$W/gate-runs"
exit \$rc
SH
  printf 'gate-full=bash %s/slow-gate.sh\n' "$W" >> "$HOME_D/config/trunk-policy"
  [ -z "${2-}" ] || printf '%s\n' "$2" >> "$HOME_D/config/trunk-policy"
}
starts() { grep -c '^start' "$W/gate-runs" 2>/dev/null || true; }
kick() {  # one check sweep that does not wait for the landings it starts
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" || fail "the check must not fail"
}
settle() {  # <base> <n>: sweep until n lanes are on the trunk over <base> (a held-back lane starts when the lane ahead ends), then wait for the landings to end
  local _
  for _ in $(seq 1 300); do
    kick >/dev/null
    [ "$(git -C "$PROJ" rev-list --count "$1..trunk")" -ge "$2" ] && ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && return 0
    sleep 0.2
  done
}
wait_for() {  # <what> <command...>: poll a condition for up to 20 seconds
  local what=$1 _; shift
  for _ in $(seq 1 200); do "$@" && return 0; sleep 0.1; done
  fail "never reached: $what"
}
front_published() { [ -s "$HOME_D/state/trunk-front-proj" ]; }
has_starts() { [ "$(starts)" -ge "$1" ] 2>/dev/null; }
ts() { awk -v w="$1" -v n="$2" '$1 == w { c++; if (c == n) print $2 }' "$W/gate-runs"; }  # the n-th start|end time

test_two_lanes_land_in_about_one_gate() {
  local base
  slow_world two; base=$(tip); : > "$W/hold"
  lane a1 'a1' a1.txt; kick; wait_for 'the first lane gates' has_starts 1; wait_for 'the first lane is the front' front_published
  lane b1 'b1' b1.txt; kick; wait_for 'the second gate starts while the first is open' has_starts 2
  # A third lane waits while two gates run: at most 2 gates at once.
  lane c1 'c1' c1.txt; kick; sleep 1
  [ "$(starts)" = 2 ] || fail "at most 2 gates run at once, got $(starts) starts while two lanes were in flight"
  touch "$W/release"; settle "$base" 3
  [ "$(starts)" = 3 ] || fail "three lanes take 3 gate runs (the second is not gated again, the third waits for a free gate), got $(starts)"
  awk -v s2="$(ts start 2)" -v e1="$(ts end 1)" 'BEGIN { exit !(s2 < e1) }' || fail "the second gate must start before the first ends: $(cat "$W/gate-runs")"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket a1,ticket b1,ticket c1" ] || fail "both land in order: $(git -C "$PROJ" log --format=%s "$base..trunk")"
  [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = 3 ] || fail "one commit per lane on the trunk"
  [ ! -e "$HOME_D/state/trunk-front-proj" ] || fail "a landed front leaves no record"
  pass 'a lane ready during the first gate is gated on top of it and both land after one gate each, a third waits'
}

test_a_red_first_lane_costs_the_second_one_more_gate() {
  local base
  slow_world red; base=$(tip); : > "$W/hold"
  lane r1 'BAD' work.txt; kick; wait_for 'the first lane gates' has_starts 1; wait_for 'the first lane is the front' front_published
  lane r2 'r2' r2.txt; kick; wait_for 'the second gate starts while the first is open' has_starts 2
  touch "$W/release"; settle "$base" 1
  [ "$(starts)" = 3 ] || fail "a red first lane costs the second one more gate (3 runs), got $(starts)"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket r2" ] || fail "only the second lane lands: $(git -C "$PROJ" log --format=%s "$base..trunk")"
  grep -qs '^final' "$HOME_D"/data/jg-trunk-landing/r1.*.state || fail "the red lane is returned for good"
  pass 'a red first lane is returned and the second lands after one more gate'
}

test_one_slot_lands_one_lane_at_a_time() {
  local base
  slow_world one 'gate-slots=1'; base=$(tip)
  lane s1 's1' s1.txt; kick; wait_for 'the first lane gates' has_starts 1
  lane s2 's2' s2.txt; kick
  [ "$(starts)" = 1 ] || fail "with gate-slots=1 the second lane must not start while the first gates, got $(starts) starts"
  settle "$base" 2
  awk -v s2="$(ts start 2)" -v e1="$(ts end 1)" 'BEGIN { exit !(s2 >= e1) }' || fail "the gates must not overlap with gate-slots=1: $(cat "$W/gate-runs")"
  [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = 2 ] || fail "both lanes still land"
  pass 'gate-slots=1 keeps the one-at-a-time rule'
}

test_two_lanes_land_in_about_one_gate
test_a_red_first_lane_costs_the_second_one_more_gate
test_one_slot_lands_one_lane_at_a_time
