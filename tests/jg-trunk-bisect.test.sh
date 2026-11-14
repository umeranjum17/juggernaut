#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh `land-batch`: the two halves of a red stack gate at once (H29d, core/trunk-landing/bisect.sh).
# Through tests/jg-trunk-fixture.sh it runs bin/jg-trunk.sh with the real gate chain over real git repositories.
#
# T17 A stack of 4 with one lane that breaks a script no lane of the stack changed (an unclear red, so it is halved): the green half lands,
#    the guilty lane is returned alone and its green sibling lands. The gates of the two halves overlap in time (two at once), the whole
#    search takes 3 rounds of one gate time (the stack, the halves, the lanes), and `gate-slots=1` keeps the halves one after the other.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"
# shellcheck disable=SC2034 # read by the fixture
JG_TRUNK_FIXTURE_CACHE=1

# shellcheck disable=SC2016 # the gate body is written out verbatim and expands when the gate runs it
bisect_world() {  # <name> <gate-slots>
  world "$1"; rig
  printf 'gate-full=echo start >> "%s/events"; sleep 1; bash %s/rig.sh --all; rc=$?; echo end >> "%s/events"; exit $rc\n' "$W" "$W" "$W" >> "$HOME_D/config/trunk-policy"
  printf 'gate-slots=%s\n' "$2" >> "$HOME_D/config/trunk-policy"
  # The tip holds a script that reads a file a lane may change; no lane of the stack changes the script itself.
  git -C "$PROJ" worktree add -q -b seed "$W/seed" trunk
  commit_in "$W/seed" t/x.test.sh '! grep -qs BAD g9.txt' "seed x"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/seed" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
}
landed() { git -C "$PROJ" log --reverse --format=%s "$1..trunk" | paste -sd, -; }
gates() { grep -c '^start' "$W/events"; }
most_at_once() { awk '$1 == "start" { n++; if (n > m) m = n } $1 == "end" { n-- } END { print m + 0 }' "$W/events"; }

search() {  # <world> <gate-slots>: a stack of 4, the third lane is the red one
  local base out
  bisect_world "$1" "$2"; base=$(tip)
  lane b1 'exit 0' t/b1.test.sh; lane b2 'exit 0' t/b2.test.sh; lane b3 BAD g9.txt; lane b4 'exit 0' t/b4.test.sh
  out=$(trunk land-batch b1 b2 b3 b4 2>&1) || fail "a red stack must still land its green part: $out"
  assert_contains "$out" "returned b3: REFUSED: this lane is the red in its batch" "the guilty lane is found"
  case $out in *"returned b1"*|*"returned b2"*|*"returned b4"*) fail "a green lane must not be returned: $out" ;; esac
  [ "$(landed "$base")" = "ticket b1,ticket b2,ticket b4" ] || fail "the green lanes land in order: $(landed "$base")"
}

test_both_halves_gate_at_once() {
  search two 2
  [ "$(most_at_once)" = 2 ] || fail "the two halves must gate at the same time, most at once was $(most_at_once)"
  [ "$(gates)" = 5 ] || fail "stack, two halves, two lanes make 5 gates, got $(gates)"
  pass 'a red stack of 4: the halves gate at once, the guilty lane is found in 3 rounds'
}

test_one_slot_keeps_the_halves_in_turn() {
  search one 1
  [ "$(most_at_once)" = 1 ] || fail "gate-slots=1 must run one gate at a time, most at once was $(most_at_once)"
  pass 'gate-slots=1: the halves gate one after the other'
}

test_both_halves_gate_at_once
test_one_slot_keeps_the_halves_in_turn
