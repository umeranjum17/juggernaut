#!/usr/bin/env bash
# Integration test for the returns a moving trunk causes (core/trunk-landing/returns-baseline.sh, bin/jg-trunk.sh `land`), through the
# real landing check and the real admission and rebase path over real git repositories (tests/jg-trunk-fixture.sh). The stand-in gate
# holds one named lane until the case lets its n-th run end, so a second landing moves the trunk while that lane is gated, and the
# case never depends on a wall clock. The movers land through the same `jg-trunk.sh land` the check starts.
#
# M1 A conflict return: two lanes edit one file off the same tip. The first lands while the second is gated; the second is then
#    admitted on the new tip, its rebase conflicts, and it is returned with the conflicting path. It is gated once and never again.
# M2 A trunk-moved return: a lane that conflicts with nothing is gated while three other lanes land, one per gate round. Each move
#    costs it a whole gate run (3 runs), and after the third move it is returned "the trunk kept moving". One move less and it lands.
# M3 One move: a lane moved under once is rebased, gated one more time, and lands (2 runs).
# M4 A gate-failure return, and the baseline (core/trunk-landing/returns-baseline.sh) over the attempt records those landings left: it
#    prints one return for each cause, split by cause and by source head, and names no return for a lane that landed.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"
# shellcheck disable=SC2034 # read by the fixture
JG_TRUNK_FIXTURE_CACHE=1

# The gate logs each run's start and end by lane. A lane with a file $W/hold-<lane> stays open at its n-th run until $W/go-<lane>-<n>.
# gate-slots=1 keeps the movers off the speculative position, so a mover lands at once while the held lane gates on the tip it read.
# shellcheck disable=SC2016 # the gate body is written out verbatim and expands when the gate runs it
move_world() {  # <name>
  world "$1"
  ln -sn "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  cat > "$W/hold-gate.sh" <<SH
#!/usr/bin/env bash
id=\$(git log -1 --format=%s | sed 's/^ticket //')
printf 'start %s\n' "\$id" >> "$W/gate-runs"
n=\$(grep -c "^start \$id\$" "$W/gate-runs")
if [ -f "$W/hold-\$id" ]; then for _ in \$(seq 1 300); do [ -f "$W/go-\$id-\$n" ] && break; sleep 0.1; done; fi
printf 'end %s\n' "\$id" >> "$W/gate-runs"
! grep -rq BAD --include='*.txt' .
SH
  printf 'gate-full=bash %s/hold-gate.sh\ngate-slots=1\n' "$W" >> "$HOME_D/config/trunk-policy"
}
runs() { local n; n=$(grep -c "^start $1\$" "$W/gate-runs" 2>/dev/null); echo "${n:-0}"; }  # <lane>: gate runs it has started
kick() { JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null || fail "the check must not fail"; }
wait_for() {  # <what> <command...>: poll a condition for up to 30 seconds
  local what=$1 _; shift
  for _ in $(seq 1 300); do "$@" && return 0; sleep 0.1; done
  fail "never reached: $what"
}
runs_reach() { [ "$(runs "$1")" -ge "$2" ]; }  # <lane> <n>
settled() { [ -z "$(jg_test_detached_alive)" ]; }  # no landing job of the check is alive
trunk_has() { [ "$(git -C "$PROJ" rev-list --count "$1..trunk")" = "$2" ]; }  # <base> <n>
cause_row() { awk -v c="$2" -v r="$3" -v h="$4" '$1 == c && $2 == r && $3 == h { ok = 1 } END { exit !ok }' <<<"$1"; }  # <baseline output> <cause> <returns> <heads>
# refused <lane>: an attempt of the check has recorded its return, and no job is left running.
refused() { settled && grep -qs '^REFUSED' "$HOME_D"/data/jg-trunk-landing/"$1".*.attempt-*/landing.log; }
# quiet <id>: the lane's done line is taken back, so the check never starts it; the case lands it by hand through the same lander.
quiet() { rm -f "$HOME_D/state/$1.status"; }
# mover <id> <file>: a lane that conflicts with nothing lands through the same lander while another lane is gated.
mover() { lane "$1" "$1" "$2.txt"; quiet "$1"; trunk land "$1" >/dev/null 2>&1 || fail "mover $1 must land"; }
# attempts <lane>: the landing attempts the check recorded for the lane (one per run of the lander)
attempts() { find "$HOME_D/data/jg-trunk-landing" -maxdepth 1 -type d -name "$1.*.attempt-*" 2>/dev/null | wc -l; }
# the return the check recorded for the lane: the first REFUSED line of its attempt log
verdict() { grep -hm1 '^REFUSED' "$HOME_D"/data/jg-trunk-landing/"$1".*.attempt-*/landing.log 2>/dev/null | head -n 1; }

test_a_lane_gated_while_another_lands_is_returned_for_the_conflict() {
  local base
  move_world conflict; base=$(tip); : > "$W/hold-cb"
  lane cb 'second'; kick; wait_for 'the second lane gates' runs_reach cb 1
  lane ca 'first'; quiet ca; trunk land ca >/dev/null 2>&1 || fail "the first lane must land while the second is gated"
  touch "$W/go-cb-1"; wait_for 'the second lane is returned' refused cb
  [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = 1 ] || fail "only the first lane is on the trunk: $(git -C "$PROJ" log --format=%s "$base..trunk")"
  assert_contains "$(verdict cb)" "conflicts with trunk" "the second lane is returned for a conflict"
  assert_contains "$(verdict cb)" "work.txt" "the return names the conflicting path"
  [ "$(runs cb)" = 1 ] || fail "a conflict stops at the rebase, before any second gate, got $(runs cb) runs"
  # The conflict was judged on the tip the rebase met, so the same head is not judged again while that tip stands.
  kick; wait_for 'the check settles' settled
  [ "$(attempts cb)" = 1 ] || fail "a conflict a concurrent landing caused is judged once for its head, got $(attempts cb) attempts"
  [[ $(cat "$HOME_D"/data/jg-trunk-landing/cb.????????????????????????????????????????.state) == final* ]] || fail "the verdict still holds after the check ran again, not a stuck running line: $(cat "$HOME_D"/data/jg-trunk-landing/cb.????????????????????????????????????????.state)"
  [ "$(cat "$HOME_D"/data/jg-trunk-landing/cb.????????????????????????????????????????.tip)" = "$(tip)" ] || fail "the verdict is stored with the tip the rebase met"
  pass 'a lane gated while another lands is rebased on the new tip, conflicts, and is returned with its path after one gate, and judged once'
}

test_a_lane_whose_trunk_keeps_moving_is_gated_again_each_time_and_then_returned() {
  local base
  move_world moved; base=$(tip); : > "$W/hold-tb"
  lane tb 'tb' tb.txt; kick; wait_for 'the lane gates' runs_reach tb 1
  mover m1 m1; touch "$W/go-tb-1"; wait_for 'one move costs a second gate run' runs_reach tb 2
  mover m2 m2; touch "$W/go-tb-2"; wait_for 'a second move costs a third gate run' runs_reach tb 3
  mover m3 m3; touch "$W/go-tb-3"; wait_for 'the lane is returned' refused tb
  [ "$(runs tb)" = 3 ] || fail "the lander gates a lane at most 3 times, got $(runs tb)"
  assert_contains "$(verdict tb)" "the trunk kept moving while tb was gated" "the lane is returned because the trunk kept moving"
  ! git -C "$PROJ" log --format=%s "$base..trunk" | grep -q 'ticket tb' || fail "the returned lane is not on the trunk"
  [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = 3 ] || fail "the three movers landed"
  pass 'each trunk move under a gated lane costs a whole gate run, and a lane moved under three times is returned as trunk moved'
}

test_a_lane_moved_under_once_lands_after_a_second_gate() {
  local base
  move_world once; base=$(tip); : > "$W/hold-ob"
  lane ob 'ob' ob.txt; kick; wait_for 'the lane gates' runs_reach ob 1
  mover o1 o1; touch "$W/go-ob-1"; wait_for 'the lane is gated again' runs_reach ob 2
  touch "$W/go-ob-2"; wait_for 'the lane lands' settled; wait_for 'the trunk holds both lanes' trunk_has "$base" 2
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket o1,ticket ob" ] || fail "both land: $(git -C "$PROJ" log --format=%s "$base..trunk")"
  [ "$(runs ob)" = 2 ] || fail "one move costs exactly one more gate run, got $(runs ob)"
  pass 'a lane moved under once is rebased and lands after exactly one more gate run'
}

test_a_red_lane_is_returned_for_the_gate_and_the_baseline_names_each_cause() {
  local out
  move_world baseline; touch "$W/hold-cb" "$W/hold-tb"
  # One home, three returns: a trunk move (tb), a red gate (rb) and a conflict (cb), and one lane that landed (ca). The conflict comes last:
  # the check judges a conflict that a landing beside it caused once more, and that second launch holds the queue for 2 minutes.
  lane tb 'tb' tb.txt; kick; wait_for 'tb gates' runs_reach tb 1
  for n in 1 2 3; do mover "m$n" "m$n"; touch "$W/go-tb-$n"; [ "$n" = 3 ] || wait_for "tb gates run $((n + 1))" runs_reach tb $((n + 1)); done
  wait_for 'tb is returned' refused tb; quiet tb  # its worker would fix it; the case leaves it returned once
  lane rb 'BAD' rb.txt; kick; wait_for 'rb is returned' refused rb; quiet rb
  lane cb 'second'; kick; wait_for 'cb gates' runs_reach cb 1
  lane ca 'first'; quiet ca; trunk land ca >/dev/null 2>&1 || fail "ca must land"
  touch "$W/go-cb-1"; wait_for 'cb is returned' refused cb; quiet cb
  assert_contains "$(verdict rb)" "gate 'full' failed" "the red lane is returned for the gate"
  out=$("$ROOT/core/trunk-landing/returns-baseline.sh" "$HOME_D" --heads) || fail "the baseline must run: $out"
  cause_row "$out" conflict 1 1 || fail "one conflict return on one head: $out"
  cause_row "$out" trunk-moved 1 1 || fail "one trunk-moved return on one head: $out"
  cause_row "$out" gate-failure 1 1 || fail "one gate-failure return on one head: $out"
  awk '$1 == "all" && $3 == 3 && $4 == 3 { ok = 1 } END { exit !ok }' <<<"$out" || fail "three returns on three heads, none for the lane that landed: $out"
  [ "$(grep -c '^cb\.\|^tb\.\|^rb\.' <<<"$out")" = 3 ] || fail "the head table names the three returned lanes: $out"
  ! grep -q '^ca\.' <<<"$out" || fail "the lane that landed is no return: $out"
  assert_contains "$out" "conflict=1" "the table splits a head's returns by cause"
  pass 'the baseline reads the attempt records and prints one return for each cause, per source head'
}

test_the_baseline_refuses_a_home_with_no_attempt_records() {
  local out rc=0
  move_world empty
  out=$("$ROOT/core/trunk-landing/returns-baseline.sh" "$HOME_D" 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "a home with no landing record is refused with 2, got $rc: $out"
  assert_contains "$out" "no landing attempt was recorded" "the refusal says why"
  pass 'the baseline reports a home with no landing records instead of printing zeros'
}

test_a_lane_gated_while_another_lands_is_returned_for_the_conflict
test_a_lane_whose_trunk_keeps_moving_is_gated_again_each_time_and_then_returned
test_a_lane_moved_under_once_lands_after_a_second_gate
test_a_red_lane_is_returned_for_the_gate_and_the_baseline_names_each_cause
test_the_baseline_refuses_a_home_with_no_attempt_records
printf 'jg-trunk-base-movement: ok\n'
