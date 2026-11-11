#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh `land-batch`: a red stack is not halved when one lane clearly owns the red.
# Through tests/jg-trunk-fixture.sh it runs bin/jg-trunk.sh with the real gate chain over real git repositories.
#
# T16 A stack of 3 with 1 red lane runs 2 gates, not 3 or more: the gate names the failing script, the one lane whose changed files hold it
#    is set aside, the rest is gated once and lands, and the owner is returned (final, reported once). An unclear red still halves: a red
#    script no lane of the stack changed. A pick that does not hold (the rest is red too) falls back to halving, returning only the guilty lane.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"
# shellcheck disable=SC2034 # read by the fixture
JG_TRUNK_FIXTURE_CACHE=1

# shellcheck disable=SC2016 # the gate body is written out verbatim and expands when the gate runs it
pick_world() {  # <name>
  world "$1"; rig
  printf 'gate-full=echo run >> "%s/gate-runs"; bash %s/rig.sh --all\n' "$W" "$W" >> "$HOME_D/config/trunk-policy"
}
runs() { [ -f "$W/gate-runs" ] && grep -c . "$W/gate-runs" || echo 0; }
landed() { git -C "$PROJ" log --reverse --format=%s "$1..trunk" | paste -sd, -; }

test_a_red_stack_with_a_clear_owner_costs_one_more_gate() {
  local base out
  pick_world owned; base=$(tip)
  lane k1 'exit 0' t/k1.test.sh; lane k2 'echo "not ok - k2 breaks" >&2; exit 1' t/k2.test.sh; lane k3 'exit 0' t/k3.test.sh
  out=$(trunk land-batch k1 k2 k3 2>&1) || fail "a red stack must still land its green part: $out"
  [ "$(runs)" = 2 ] || fail "a stack of 3 with 1 red lane takes 2 gates (stack, then the rest), got $(runs)"
  assert_contains "$out" "returned k2: REFUSED: this lane is the red in its batch" "the owner of the red is returned"
  assert_contains "$out" "refusal-class k2: final" "a red the lane caused is final"
  case $out in *"returned k1"*|*"returned k3"*) fail "a green lane must not be returned: $out" ;; esac
  [ "$(landed "$base")" = "ticket k1,ticket k3" ] || fail "the green part lands in order: $(landed "$base")"
  [ "$(grep -c '^landed k' <<<"$out")" = 2 ] || fail "each green lane reports its landing: $out"
  pass 'a stack of 3 with 1 red lane: 2 gates, the owner returned, the green part landed'
}

test_an_unclear_red_still_halves() {
  local base out
  pick_world unclear
  # The tip holds a script that reads a file a lane may change; no lane of the stack changes the script itself.
  git -C "$PROJ" worktree add -q -b seed "$W/seed" trunk
  commit_in "$W/seed" t/x.test.sh '! grep -qs BAD g9.txt' "seed x"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/seed" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"; base=$(tip)
  lane u1 'exit 0' t/u1.test.sh; lane u2 'exit 0' t/u2.test.sh; lane u3 BAD g9.txt
  out=$(trunk land-batch u1 u2 u3 2>&1) || fail "a red stack must still land its green part: $out"
  assert_contains "$out" "returned u3: REFUSED: this lane is the red in its batch" "the guilty lane is found by halving"
  [ "$(landed "$base")" = "ticket u1,ticket u2" ] || fail "the green part lands: $(landed "$base")"
  [ "$(runs)" = 3 ] || fail "an unclear red halves: stack, first half, second lane of the rest (the last is known red), got $(runs)"
  pass 'an unclear red still halves'
}

test_a_pick_that_does_not_hold_falls_back_to_halving() {
  local base out
  pick_world fallback; base=$(tip)
  # j3's own script is red, and the gate names only it. j2 passes only while j3's script is there, so the rest of the stack is red too:
  # the pick is wrong, and the stack is halved as before. j1 lands; j2 and j3 are each returned alone.
  lane j1 'exit 0' t/j1.test.sh; lane j2 '[ -f t/j3.test.sh ]' t/j2.test.sh; lane j3 'echo "not ok - j3" >&2; exit 1' t/j3.test.sh
  out=$(trunk land-batch j1 j2 j3 2>&1) || fail "a red stack must still land its green part: $out"
  assert_contains "$out" "returned j3: REFUSED: this lane is the red in its batch" "the red lane is returned"
  assert_contains "$out" "returned j2: REFUSED: this lane is the red in its batch" "the lane that fails without it is returned after the pick fails"
  case $out in *"returned j1"*) fail "the green lane must not be returned: $out" ;; esac
  [ "$(landed "$base")" = "ticket j1" ] || fail "only the green lane lands: $(landed "$base")"
  [ "$(runs)" -gt 2 ] || fail "a pick that does not hold costs the halving runs, got $(runs)"
  pass 'a pick that does not hold falls back to halving'
}

test_a_red_stack_with_a_clear_owner_costs_one_more_gate
test_an_unclear_red_still_halves
test_a_pick_that_does_not_hold_falls_back_to_halving
