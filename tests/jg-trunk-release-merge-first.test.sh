#!/usr/bin/env bash
# Integration test for the standing release word (report fable-jg-7v6uw, slice 2): under the owner rule "Standing release
# word" (config/trunk-release-waiver, written by `jg-trunk.sh waiver --release`) a green release pull request merges by
# itself and the next trunk version is cut in the same pass. The real callers run: bin/jg-trunk.sh release, then the
# registered merge-on-green check over the home; the forge, the merge command and the evidence lint are stand-ins.
#
# T1 Rule standing, release PR open and green: the record carries merge=approved and the rule, the check merges through
#    bin/jg-pr-merge.sh for the release task and its URL, rolls the trunk over in the same pass (trunk-v2 cut), and names
#    the merge in one wake line; a merge more than 5 minutes after the proof's receipt is called out as over the target.
# T2 A red head, or a check that has not reported: not merged, nothing rolled over.
# T3 The rule removed (the record still says merge=approved): not merged. The rule never written: the record carries no approval.
# T4 A release again while the open release PR is green and the rule stands: nothing is pushed into it and the word stays.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

U=https://github.com/o/r/pull
RULE=owner-rule-5f0e638d
ID=release-proj-trunk

# One release PR (number 1), open until the merge stand-in merges it. The gh-axi stand-in answers its state; jg-pr-state
# prints what the file ci-state holds (nothing is green); jg-pr-merge records its call and merges like the forge does.
world_with_release() {  # <name>
  world "$1"
  cat > "$W/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/gh-calls"
case "\$2" in
  view) printf 'state: %s\n' "\$(cat "$W/pr-state-\$3" 2>/dev/null || echo open)" ;;
  list) printf 'count: 0\n' ;;
  create) printf '$U/1\n' ;;
esac
SH
  cat > "$W/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\$1 \$2 \$*" in
  'pr view '*isDraft*) printf '{"isDraft":false}\n' ;;
  'pr view '*headRefOid*) git -C "$PROJ" rev-parse trunk ;;
  'pr view '*baseRefName*) printf 'main\ttrunk\n' ;;
  'api '*) printf '{}\n' ;;
esac
exit 0
SH
  cat > "$W/root/bin/jg-pr-state.sh" <<SH
#!/usr/bin/env bash
cat "$W/ci-state" 2>/dev/null || true
SH
  cat > "$W/root/bin/jg-pr-merge.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/merge-calls"
M=\$(git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit-tree "\$(git -C "$PROJ" rev-parse 'trunk^{tree}')" -p origin/main -p "\$(git -C "$PROJ" rev-parse trunk)" -m "Merge pull request #1")
git -C "$PROJ" push -q origin "\$M:refs/heads/main"; echo merged > "$W/pr-state-1"
SH
  printf '#!/usr/bin/env bash\necho "checks-lint: PASS"\n' > "$W/checks-lint"
  ln -s "$W/root/bin" "$HOME_D/bin"   # the merge check runs the home's own bin
  chmod +x "$W/fakebin/gh-axi" "$W/fakebin/gh" "$W/root/bin/jg-pr-state.sh" "$W/root/bin/jg-pr-merge.sh" "$W/checks-lint"
  lane a1 released >/dev/null; trunk land a1 >/dev/null 2>&1 || fail "a1 must land"
  trunk word release "$PROJ" "ship a1" >/dev/null 2>&1 || fail "the release word must record"
}

# The release proof's receipt for the release head, as bin/jg-trunk-release-proof.sh publishes it; <at> is its epoch.
receipt() {  # <at>
  printf '{"schema":1,"task":"%s","mode":"local-trunk","spawn_gen":"","head":"%s","pr":"%s/1","verdict":"PASS","at":%s}\n' "$ID" "$(tip)" "$U" "$1" > "$HOME_D/state/$ID.run-receipt.json"
}
sweep_mog() {  # the registered check over the fixture home
  PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" JG_ROOT_OVERRIDE="$W/root" JG_STATE_OVERRIDE="$HOME_D/state" JG_DATA_OVERRIDE="$HOME_D/data" \
    JG_CONFIG_OVERRIDE="$HOME_D/config" JG_MOG_CHECKS_LINT="$W/checks-lint" JG_CHECK_TIMEOUT=60 \
    "$ROOT/core/merge-on-green/merge-on-green.sh" check "$HOME_D" 2>&1
}
merges() { [ -s "$W/merge-calls" ] && grep -c . "$W/merge-calls" || echo 0; }

test_a_green_release_merges_on_the_standing_word_and_rolls_over() {
  local out
  world_with_release standing
  trunk waiver "$PROJ" --rule "$RULE" --release >/dev/null 2>&1 || fail "T1: the standing word must record"
  trunk release "$PROJ" >/dev/null 2>&1 || fail "T1: the release must open"
  grep -qxF merge=approved "$HOME_D/state/$ID.meta" || fail "T1: the record must carry the standing word: $(cat "$HOME_D/state/$ID.meta")"
  grep -qxF "merge_rule=$RULE" "$HOME_D/state/$ID.meta" || fail "T1: the record must name the rule: $(cat "$HOME_D/state/$ID.meta")"
  grep -qxF yolo=off "$HOME_D/state/$ID.meta" || fail "T1: the record is not a yolo record"
  receipt "$(( $(date +%s) - 600 ))"
  out=$(sweep_mog)
  [ "$(merges)" = 1 ] || fail "T1: the green release must merge once through bin/jg-pr-merge.sh: $out"
  assert_contains "$(cat "$W/merge-calls")" "$ID $U/1" "T1: the merge is for the release task and its PR"
  assert_contains "$out" "merged $ID $U/1" "T1: the merge must be named"
  assert_contains "$out" "over the 5-minute target" "T1: a merge 10 minutes after the proof must be called out"
  git -C "$PROJ" rev-parse --verify -q refs/heads/trunk-v2 >/dev/null || fail "T1: the next trunk must be cut in the same pass: $out"
  [ "$(cat "$HOME_D/state/trunk-branch-proj")" = trunk-v2 ] || fail "T1: the project must be on the next trunk"
  assert_contains "$out" "rollover after $ID: release merged" "T1: the rollover must be named"
  [ ! -e "$HOME_D/state/$ID.status" ] || fail "T1: a release has no worker status line"
  pass 'T1 a green release merges through jg-pr-merge on the standing word, the next trunk is cut in the same pass and a slow merge is called out'
}

test_a_red_or_unreported_head_is_not_merged() {
  local out
  world_with_release red
  trunk waiver "$PROJ" --rule "$RULE" --release >/dev/null 2>&1; trunk release "$PROJ" >/dev/null 2>&1 || fail "T2: the release must open"
  receipt "$(date +%s)"
  printf 'CHECK: CI required (failure)\n' > "$W/ci-state"; out=$(sweep_mog)
  [ "$(merges)" = 0 ] || fail "T2: a red head must not merge: $out"
  printf 'CHECK: CI required (pending)\n' > "$W/ci-state"; out=$(sweep_mog)
  [ "$(merges)" = 0 ] || fail "T2: a check that has not reported must not merge: $out"
  git -C "$PROJ" rev-parse --verify -q refs/heads/trunk-v2 >/dev/null && fail "T2: nothing may roll over before the merge"
  pass 'T2 a red head and a check that has not reported are not merged'
}

test_without_the_rule_nothing_merges() {
  local out
  world_with_release norule
  trunk release "$PROJ" >/dev/null 2>&1 || fail "T3: the release must open"
  ! grep -q '^merge=' "$HOME_D/state/$ID.meta" || fail "T3: no rule, no approval in the record: $(cat "$HOME_D/state/$ID.meta")"
  receipt "$(date +%s)"; out=$(sweep_mog)
  [ "$(merges)" = 0 ] || fail "T3: a release without the standing word must not merge: $out"
  printf 'merge=approved\n' >> "$HOME_D/state/$ID.meta"   # an approval left in the record after the rule went
  out=$(sweep_mog)
  [ "$(merges)" = 0 ] || fail "T3: an approval with no standing rule must not merge: $out"
  pass 'T3 with the rule removed the release is not merged, even when the record still says approved'
}

test_a_green_open_release_is_not_pushed_into() {
  local out head
  world_with_release nopush
  trunk waiver "$PROJ" --rule "$RULE" --release >/dev/null 2>&1; trunk release "$PROJ" >/dev/null 2>&1 || fail "T4: the release must open"
  lane a2 second >/dev/null; trunk land a2 >/dev/null 2>&1 || fail "T4: a2 must land"
  trunk word release "$PROJ" "ship a2" >/dev/null 2>&1
  head=$(git --git-dir="$W/origin.git" rev-parse refs/heads/trunk)
  out=$(trunk release "$PROJ" 2>&1) && fail "T4: a green open release must not take a push: $out"
  assert_contains "$out" "merges on the captain's standing word" "T4: the refusal must say why"
  [ "$(git --git-dir="$W/origin.git" rev-parse refs/heads/trunk)" = "$head" ] || fail "T4: nothing may be pushed into the green release"
  [ -f "$HOME_D/state/trunk-word-release-proj" ] || fail "T4: the word stays for the next release"
  printf 'CHECK: CI required (failure)\n' > "$W/ci-state"
  trunk release "$PROJ" >/dev/null 2>&1 || fail "T4: a red release PR still takes its fix"
  [ "$(git --git-dir="$W/origin.git" rev-parse refs/heads/trunk)" = "$(tip)" ] || fail "T4: the fix must be pushed into the red release"
  pass 'T4 a green open release takes no push under the standing word; a red one still takes its fix'
}

test_a_green_release_merges_on_the_standing_word_and_rolls_over
test_a_red_or_unreported_head_is_not_merged
test_without_the_rule_nothing_merges
test_a_green_open_release_is_not_pushed_into
printf 'jg-trunk-release-merge-first: ok\n'
