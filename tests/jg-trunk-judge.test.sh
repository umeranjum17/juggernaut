#!/usr/bin/env bash
# Integration test for one judge per commit (H29g, core/trunk-verify/judge.sh) through bin/jg-trunk.sh and the real bin/jg-alert.sh.
# The lander's tip run and the line's verify (and the nightly run) judge one tree. When they see the same failed scripts nothing is
# raised; when they see different ones the second judge raises the alert judge-split once, naming both verdicts, and the ledger
# data/trunk/judge-<project>.tsv holds each judge's verdict. A judge that runs again replaces its own verdict.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# shellcheck disable=SC2016 # the script body is written out verbatim and expands when the gate runs it
test_two_judges_that_agree_raise_nothing_and_two_that_differ_raise_judge_split() {
  local c tree led alerts out
  world judge; rig
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  # Both gates run the same scripts; the landing gate runs them at the landing, the verify gate runs them whole.
  printf 'gate-full=bash %s/rig.sh --all\ngate-verify=bash %s/rig.sh --all\ngate-slots=1\n' "$W" "$W" >> "$HOME_D/config/trunk-policy"
  led="$HOME_D/data/trunk/judge-proj.tsv"; alerts="$HOME_D/state/alerts"
  # The pin sits on the base so the verify judges the commit against its parent (full_gate), as the lander's tip run did.
  tip > "$HOME_D/state/trunk-green-proj"
  lane j1 "[ ! -e $W/split ] || { echo 'not ok - split' >&2; exit 1; }" t/s.test.sh
  trunk land j1 >/dev/null 2>&1 || fail "j1 must land: $(trunk land j1 2>&1)"
  c=$(tip); tree=$(git -C "$PROJ" rev-parse "$c^{tree}")
  [ "$(awk -F'\t' -v t="$tree" '$2 == t && $4 == "tip" && $5 == "-"' "$led" | grep -c .)" = 1 ] || fail "the lander's tip run must keep a green verdict for the tree: $(cat "$led" 2>&1)"
  # Agreement: the verify sees the same green.
  trunk verify "$PROJ" "$c" > "$W/v1.out" 2>&1 || fail "the verify must be green: $(cat "$W/v1.out")"
  [ "$(awk -F'\t' -v t="$tree" '$2 == t' "$led" | cut -f4 | sort | paste -sd, -)" = tip,verify ] || fail "the tip run and the verify must each keep a verdict: $(cat "$led")"
  ! grep -q judge-split "$W/v1.out" || fail "two agreeing judges must not say judge-split: $(cat "$W/v1.out")"
  compgen -G "$alerts/judge-split--*" >/dev/null && fail "two agreeing judges raise no alert"
  # Disagreement: the same tree, and now the script fails for the verify, which judges it against its parent.
  : > "$W/split"
  trunk verify "$PROJ" "$c" > "$W/v2.out" 2>&1 && fail "a verify that sees a red the tip run did not see must not be green"
  assert_contains "$(cat "$W/v2.out")" "judge-split: two verdicts on ${c:0:12}" "the verify says the two judges split"
  assert_contains "$(cat "$W/v2.out")" "tip=green" "the split names the tip run's verdict"
  [ -f "$alerts/judge-split--proj-${tree:0:12}.rec" ] || fail "judge-split must be raised for the tree: $(ls "$alerts" 2>&1)"
  [ "$(find "$alerts" -name 'judge-split--*.rec' | grep -c .)" = 1 ] || fail "one alert per tree"
  # A judge that runs again replaces its own verdict: once the verify agrees with the tip run the verdicts agree again.
  out=$(JG_HOME="$HOME_D" JG_JUDGE_REPO="$PROJ" bash "$HOME_D/core/trunk-verify/judge.sh" record verify "$c" --project proj 2>&1)
  assert_equals agree "$out" "a judge that now agrees replaces its verdict"
  pass 'a tip run and a verify that agree raise nothing, and a verify that differs raises judge-split once, and a judge that runs again replaces its verdict'
}

test_two_judges_that_agree_raise_nothing_and_two_that_differ_raise_judge_split
printf 'jg-trunk-judge: ok\n'
