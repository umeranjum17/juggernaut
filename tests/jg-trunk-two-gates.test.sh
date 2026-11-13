#!/usr/bin/env bash
# Integration test for two landing gates at once (core/trunk-landing/trunk-landing.sh, bin/jg-trunk.sh `land`), through the real
# check and the real gate chain over real git repositories (tests/jg-trunk-fixture.sh). The gate is a stand-in that takes 2 seconds
# and logs its start and end, so each case reads overlap and order from the log, never from a wall clock.
#
# G1 A lane that is ready while the first one gates starts at once, is gated on top of the first one's commit, and both land in order
#    after one gate each (the second started before the first ended). A third lane waits: at most 2 gates at once, then it lands too.
# G2 When the first lane is red, the second lands after one more gate (3 gate runs): it is gated again on the tip, the first is returned.
# G3 With gate-slots=1 the second lane waits for the first one's end: no overlap, and both still land.
# G4 The window (core/trunk-landing/window.sh): a red gate halves it to one gate, so the next lane gates alone and a lane ready meanwhile
#    waits; a landing grows it back to two and the waiting lane lands. gate-slots=1 keeps it at one.
# G5 A chain of fronts (gate-slots=3, heavy_slots=3): three lanes gate at once, each on the commit of the one below, a fourth waits for a
#    position, and all land in order after one gate each. A red lane in the middle is returned and the lane above it gates once more.
# G6 Queues split by tests (core/trunk-landing/partition.sh): two lanes whose changes select no common script gate side by side, each at the front of
#    its own queue (neither is gated on the other's commit) and both land; two lanes that select one script share one queue's chain; a lane that
#    selects the scripts of two running queues waits until one has ended, and still lands.
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
front_published() { compgen -G "$HOME_D/state/trunk-front-proj:*" >/dev/null; }  # a lane gates in its queue's chain: trunk-front-<project>:<queue>[@<position>]
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
  ls "$HOME_D"/state/trunk-front-proj* >/dev/null 2>&1 && fail "a landed front leaves no record"
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

test_a_red_gate_halves_the_window_and_a_landing_grows_it() {
  local base; win() { cat "$HOME_D/state/trunk-window-proj" 2>/dev/null; }; win_is() { [ "$(win)" = "$1" ]; }
  slow_world win; base=$(tip)
  lane w0 'BAD' work.txt; kick; wait_for 'the red lane is returned' grep -qs '^final' "$HOME_D"/data/jg-trunk-landing/w0.*.state
  wait_for 'the window halves on the red' win_is 1
  : > "$W/gate-runs"; : > "$W/hold"
  lane w1 'w1' w1.txt; kick; wait_for 'the next lane gates' has_starts 1; wait_for 'it is the front' front_published
  lane w2 'w2' w2.txt; kick; sleep 1
  [ "$(starts)" = 1 ] || fail "with the window at 1 a second lane must wait while the first gates, got $(starts) starts"
  touch "$W/release"; settle "$base" 2
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket w1,ticket w2" ] || fail "both land in order: $(git -C "$PROJ" log --format=%s "$base..trunk")"
  [ "$(win)" = 2 ] || fail "two landings grow the window back to its cap of 2, got $(win)"
  pass 'a red gate halves the window, a lane waits behind the one gate, and landings grow it back'
}

deep_world() { slow_world "$1" 'gate-slots=3'; mkdir -p "$HOME_D/config"; printf 'heavy_slots=3\n' > "$HOME_D/config/lane-scale"; }

test_a_deep_chain_gates_three_lanes_at_once_and_lands_them_in_order() {
  local base
  deep_world deep; base=$(tip); : > "$W/hold"
  lane d1 'd1' d1.txt; kick; wait_for 'the first lane gates' has_starts 1; wait_for 'the first lane is the front' front_published
  lane d2 'd2' d2.txt; kick; wait_for 'the second gate starts while the first is open' has_starts 2
  lane d3 'd3' d3.txt; kick; wait_for 'the third gate starts while the first is open' has_starts 3
  compgen -G "$HOME_D/state/trunk-front-proj:*@3" >/dev/null || fail "the third lane publishes its place in the chain"
  lane d4 'd4' d4.txt; kick; sleep 1
  [ "$(starts)" = 3 ] || fail "with three positions a fourth lane waits, got $(starts) starts"
  touch "$W/release"; settle "$base" 4
  [ "$(starts)" = 4 ] || fail "four lanes take 4 gate runs (none is gated again), got $(starts)"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket d1,ticket d2,ticket d3,ticket d4" ] || fail "all land in order: $(git -C "$PROJ" log --format=%s "$base..trunk")"
  ls "$HOME_D"/state/trunk-front-proj* >/dev/null 2>&1 && fail "a landed chain leaves no record: $(ls "$HOME_D"/state/trunk-front-proj*)"
  pass 'three lanes gate at once on a chain of fronts, a fourth waits, and all land in order'
}

test_a_red_middle_lane_costs_the_lane_above_it_one_more_gate() {
  local base
  deep_world mid; base=$(tip); : > "$W/hold"
  lane m1 'm1' m1.txt; kick; wait_for 'the first lane gates' has_starts 1; wait_for 'the first lane is the front' front_published
  lane m2 'BAD' m2.txt; kick; wait_for 'the second gate starts' has_starts 2
  lane m3 'm3' m3.txt; kick; wait_for 'the third gate starts' has_starts 3
  touch "$W/release"; settle "$base" 2
  [ "$(starts)" = 4 ] || fail "the lane above a red one is gated once more (4 runs), got $(starts)"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket m1,ticket m3" ] || fail "m1 and m3 land, m2 does not: $(git -C "$PROJ" log --format=%s "$base..trunk")"
  grep -qs '^final' "$HOME_D"/data/jg-trunk-landing/m2.*.state || fail "the red lane is returned for good"
  pass 'a red middle lane is returned and the lane above it is gated again'
}

# A project whose own selector names one script per top-level directory a lane changed, as bin/jg-test-run.sh --changed --list does.
# shellcheck disable=SC2016 # the selector body is written out verbatim and expands when the lander runs it
selector_world() {  # <name> [<extra policy line>]
  slow_world "$1" "${2-}"; mkdir -p "$HOME_D/config"; printf 'heavy_slots=3\n' > "$HOME_D/config/lane-scale"
  git -C "$PROJ" worktree add -q -b seed "$W/seed" trunk
  mkdir -p "$W/seed/bin"
  printf '#!/usr/bin/env bash\ngit diff --name-only "${3:-HEAD^}" HEAD | grep / | cut -d/ -f1 | sort -u | sed "s|.*|tests/&.test.sh|"\n' > "$W/seed/bin/jg-test-run.sh"
  git -C "$W/seed" add bin/jg-test-run.sh; git -C "$W/seed" -c user.name=t -c user.email=t@example.invalid commit -q -m "seed selector"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/seed" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
}
fronts() { local f; for f in "$HOME_D"/state/trunk-front-proj*; do [ -e "$f" ] && printf '%s\n' "${f##*/}"; done; true; }
queues_running() { fronts | grep -c '^trunk-front-proj:[^@]*$' || true; }
two_queues() { [ "$(queues_running)" -ge 2 ]; }

test_lanes_that_select_different_scripts_gate_in_separate_queues() {
  local base
  selector_world split; base=$(tip); : > "$W/hold"
  lane q1 'q1' qa/x.txt; kick; wait_for 'the first lane gates' has_starts 1; wait_for 'the first lane is the front' front_published
  lane q2 'q2' qb/y.txt; kick; wait_for 'the second lane gates in a queue of its own' two_queues
  [ -e "$HOME_D/state/trunk-front-proj:q1" ] && [ -e "$HOME_D/state/trunk-front-proj:q2" ] || fail "each lane is the front of its own queue: $(fronts)"
  ls "$HOME_D"/state/trunk-front-proj*@2 >/dev/null 2>&1 && fail "no lane is gated on top of the other's commit"
  touch "$W/release"; settle "$base" 2
  [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = 2 ] || fail "both lanes land: $(git -C "$PROJ" log --format=%s "$base..trunk")"
  ls "$HOME_D"/state/trunk-front-proj* >/dev/null 2>&1 && fail "landed queues leave no front record"
  ls "$HOME_D"/data/jg-trunk-landing/*.queue >/dev/null 2>&1 && fail "a landed lane leaves no queue record"
  pass 'lanes that select no common script gate side by side in two queues and both land'
}

test_lanes_that_select_one_script_share_a_queue() {
  local base
  selector_world same; base=$(tip); : > "$W/hold"
  lane s1 's1' qa/x.txt; kick; wait_for 'the first lane gates' has_starts 1; wait_for 'the first lane is the front' front_published
  lane s2 's2' qa/z.txt; kick; wait_for 'the second lane gates on top of the first' has_starts 2
  [ "$(queues_running)" = 1 ] || fail "lanes that select one script are one queue: $(fronts)"
  compgen -G "$HOME_D/state/trunk-front-proj:s1@2" >/dev/null || fail "the second lane takes position 2 of the first queue's chain"
  touch "$W/release"; settle "$base" 2
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket s1,ticket s2" ] || fail "both land in order: $(git -C "$PROJ" log --format=%s "$base..trunk")"
  pass 'lanes that select one script share one queue and its chain'
}

test_a_lane_that_meets_two_queues_waits_for_one_of_them() {
  local base
  selector_world both 'gate-slots=3'; base=$(tip); : > "$W/hold"
  lane m1 'm1' qa/x.txt; kick; wait_for 'the first lane gates' has_starts 1; wait_for 'the first lane is the front' front_published
  lane m2 'm2' qb/y.txt; kick; wait_for 'the second queue gates' two_queues
  # m3 changes a file in each queue's directory: its selection meets both queues.
  git -C "$PROJ" worktree add -q -b fm/m3 "$W/lanes/m3" trunk
  mkdir -p "$W/lanes/m3/qa" "$W/lanes/m3/qb"; printf 'm3\n' > "$W/lanes/m3/qa/w.txt"; printf 'm3\n' > "$W/lanes/m3/qb/v.txt"
  git -C "$W/lanes/m3" add qa/w.txt qb/v.txt; git -C "$W/lanes/m3" -c user.name=t -c user.email=t@example.invalid commit -q -m "ticket m3"
  jg_write_meta "$HOME_D/state/m3.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/m3" "worktree=$W/lanes/m3" "spawn_gen=g-m3"; prove m3; ready m3
  kick; sleep 1
  [ "$(starts)" = 2 ] || fail "a lane that meets two running queues must not gate beside either, got $(starts) starts"
  grep -qs 'slot full' "$HOME_D"/data/jg-trunk-landing/m3.*.queue-why || fail "the wait is recorded: $(cat "$HOME_D"/data/jg-trunk-landing/m3.*.queue-why 2>/dev/null)"
  touch "$W/release"; settle "$base" 3
  [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = 3 ] || fail "all three land: $(git -C "$PROJ" log --format=%s "$base..trunk")"
  [ "$(git -C "$PROJ" log -1 --format=%s trunk)" = "ticket m3" ] || fail "the lane of both queues lands last"
  pass 'a lane that meets two queues waits for one of them and then lands'
}

test_two_lanes_land_in_about_one_gate
test_a_deep_chain_gates_three_lanes_at_once_and_lands_them_in_order
test_a_red_middle_lane_costs_the_lane_above_it_one_more_gate
test_a_red_gate_halves_the_window_and_a_landing_grows_it
test_a_red_first_lane_costs_the_second_one_more_gate
test_one_slot_lands_one_lane_at_a_time
test_lanes_that_select_different_scripts_gate_in_separate_queues
test_lanes_that_select_one_script_share_a_queue
test_a_lane_that_meets_two_queues_waits_for_one_of_them
