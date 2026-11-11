#!/usr/bin/env bash
# Integration test for the delivery style `local` (core/machines/styles/delivery-styles.tsv): the two old local rows are one row.
# Through tests/jg-trunk-fixture.sh it runs the real landing check (core/trunk-landing), bin/jg-trunk.sh and bin/jg-project-mode.sh over
# real git repositories:
#   - a lane with the old word (local-trunk, local-only) and a lane with the new word (local) both land, and the old records are read as before;
#   - with yolo off a lane of mode `local` waits for a word (no landing, one reason reported); the lead's recorded merge=approved lands it;
#   - with yolo on it lands by itself;
#   - a project registered `local` is a trunk project, and the accepted mode words of the spawn and the brief name `local`.
# The done-done journey journeys/delivery-style.sh runs this file.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# mode_world <name>: the fixture world with its code installed in the home, as the landing check reads it.
mode_world() { world "$1"; cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"; }

# mode_lane <id> <mode> <yolo> [<extra meta line>]: a proved, ready lane whose record carries this mode word and yolo.
mode_lane() {
  lane "$1" "$1 work" "$1.txt"
  jg_write_meta "$HOME_D/state/$1.meta" "project=$PROJ" "mode=$2" "yolo=$3" "branch=fm/$1" "worktree=$W/lanes/$1" "spawn_gen=g-$1" ${4:+"$4"}
}
landed() { git -C "$PROJ" log --format=%s trunk | grep -qx "ticket $1"; }

test_old_and_new_words_land_and_yolo_is_the_merge_switch() {
  local out
  mode_world modes
  # Old records are read as before: both old words land by themselves, whatever their yolo says.
  mode_lane old1 local-trunk off; mode_lane old2 local-only off
  sweep >/dev/null; settle_landings
  landed old1 || fail "a local-trunk record must land as before"
  landed old2 || fail "a local-only record in a trunk project must land as before"
  # The new word with yolo off waits for a word, and says why once.
  mode_lane new1 local off
  out=$(sweep)
  landed new1 && fail "yolo off: a lane of mode local must wait for a word"
  assert_contains "$out" "waits for the captain's word" "the wait names its reason"
  # The lead's recorded word lands it.
  printf 'merge=approved\n' >> "$HOME_D/state/new1.meta"
  sweep >/dev/null; settle_landings
  landed new1 || fail "merge=approved must land a lane of mode local"
  # With yolo on it lands by itself.
  mode_lane new2 local on
  sweep >/dev/null; settle_landings
  landed new2 || fail "yolo on: a lane of mode local must land by itself"
  pass "old and new words land; yolo off waits for a word, yolo on lands by itself"
}

settle_landings() {
  local _
  for _ in $(seq 1 150); do
    ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && [ -z "$(jg_test_detached_alive)" ] && return 0
    sleep 0.2
  done
  fail "the landings must settle"
}

test_a_project_registered_local_is_a_trunk_project() {
  mode_world reg
  printf -- '- proj [local +yolo] - fixture project in local mode (added 2026-11-12)\n' > "$HOME_D/data/projects.md"
  [ "$(JG_HOME="$HOME_D" JG_DATA_OVERRIDE="$HOME_D/data" bash "$ROOT/bin/jg-project-mode.sh" proj)" = "local on" ] || fail "the registry word local reads as a mode with yolo on"
  mode_lane reg1 local on
  sweep >/dev/null; settle_landings
  landed reg1 || fail "a lane of a project registered local must land on the trunk"
  # The old registry words are read as before.
  printf -- '- proj [local-only] - fixture project (added 2026-11-12)\n' > "$HOME_D/data/projects.md"
  [ "$(JG_HOME="$HOME_D" JG_DATA_OVERRIDE="$HOME_D/data" bash "$ROOT/bin/jg-project-mode.sh" proj)" = "local-only off" ] || fail "local-only is read as before"
}

test_every_entry_point_accepts_local_and_the_old_words() {
  local out m
  for m in local local-only local-trunk; do
    bash "$ROOT/bin/jg-delivery-style.sh" "$m" local || fail "$m must be a mode that publishes nothing"
  done
  out=$(bash "$ROOT/bin/jg-delivery-style.sh" --accepted | paste -sd' ' -)
  assert_equals "no-mistakes direct-PR local local-trunk local-only" "$out" "the accepted mode words"
  out=$(bash "$ROOT/bin/jg-delivery-style.sh" --list | paste -sd' ' -)
  assert_equals "no-mistakes direct-PR local" "$out" "the mode list holds one local row"
}

test_old_and_new_words_land_and_yolo_is_the_merge_switch
test_a_project_registered_local_is_a_trunk_project
test_every_entry_point_accepts_local_and_the_old_words
printf 'jg-local-mode: ok\n'
