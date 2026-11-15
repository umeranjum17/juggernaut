#!/usr/bin/env bash
# Integration test for `jg-trunk.sh forecast` and the landing check's first-sight record (tests/jg-trunk-fixture.sh).
# A clean lane prints `clean`, a same-line conflict prints `conflict <path>`, a dirty work tree stays untouched, and the real
# landing check appends one row per head to data/trunk-forecast.tsv the first time it sees the lane.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# move_trunk <name> <file> <content>: the trunk takes one more commit, moved the way the lander moves it.
move_trunk() {
  git -C "$PROJ" worktree add -q -b "$1" "$W/$1" trunk; commit_in "$W/$1" "$2" "$3" "trunk edits $2"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/$1" rev-parse HEAD)"; git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
}
tick() { JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" 2>"$W/tick.err"; }

test_forecast_names_clean_and_conflicting_lanes_and_touches_nothing() {
  local out wt before
  world forecast
  move_trunk seed notes.txt base
  lane c1 clean f1.txt
  lane c2 "lane line" notes.txt
  move_trunk edit notes.txt "trunk line"
  out=$(trunk forecast c1) || fail "forecast of a clean lane"
  assert_equals clean "$out" "a clean lane prints clean"
  wt="$W/lanes/c2"; printf 'dirty\n' > "$wt/scratch.txt"; before=$(git -C "$wt" status --porcelain)
  out=$(trunk forecast c2) || fail "forecast of a conflicting lane"
  assert_equals "conflict notes.txt" "$out" "a same-line conflict names its path"
  assert_equals "$before" "$(git -C "$wt" status --porcelain)" "the work tree is untouched"
  [ ! -e "$HOME_D/data/trunk-forecast.tsv" ] || fail "no row is written without --record"
  trunk forecast c2 --record >/dev/null; trunk forecast c2 --record >/dev/null
  assert_equals 1 "$(wc -l < "$HOME_D/data/trunk-forecast.tsv" | tr -d ' ')" "--record keeps one row per head"
  assert_contains "$(cut -f1,4,5 "$HOME_D/data/trunk-forecast.tsv")" "c2	conflict	notes.txt" "the row holds task, verdict and paths"
  pass 'forecast prints clean or the conflicting paths, never touches the work tree, and records once per head'
}

test_the_landing_check_records_the_forecast_at_first_sight() {
  world forecast2
  printf 'flush-at-ready=99\nflush-after-minutes=999999\n' >> "$HOME_D/config/trunk-policy"
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  lane c3 three f3.txt
  tick >/dev/null; tick >/dev/null
  assert_equals 1 "$(wc -l < "$HOME_D/data/trunk-forecast.tsv" | tr -d ' ')" "two ticks record one row"
  assert_contains "$(cut -f1,4,5 "$HOME_D/data/trunk-forecast.tsv")" "c3	clean	-" "the first sight records a clean forecast"
  pass 'the landing check records one forecast row when it first sees a lane'
}

test_forecast_names_clean_and_conflicting_lanes_and_touches_nothing
test_the_landing_check_records_the_forecast_at_first_sight
printf 'jg-trunk-forecast: ok\n'
