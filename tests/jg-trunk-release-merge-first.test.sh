#!/usr/bin/env bash
# Integration test for the standing release word (report fable-jg-7v6uw, slice 2): under the owner rule "Standing release
# word" (config/trunk-release-waiver, written by `jg-trunk.sh waiver --release`) a green release pull request merges by
# itself and the next trunk version is cut in the same pass. The real callers run: bin/jg-trunk.sh release, then the
# registered merge-on-green check over the home; the forge, the merge command and the evidence lint are stand-ins.
#
# T1 Rule standing, release PR open and green: the record carries merge=approved and the rule, the check merges through
#    bin/jg-pr-merge.sh for the release task and its URL, rolls the trunk over in the same pass (release/v2 cut), and names
#    the merge in one wake line; a merge more than 5 minutes after the proof's receipt is called out as over the target.
# T2 A red head, or a check that has not reported: not merged, nothing rolled over.
# T3 The rule removed (the record still says merge=approved): not merged. The rule never written: the record carries no approval.
# T4 A release again while the open release PR is green and the rule stands: nothing is pushed into it and the word stays.
# T5 yolo asked once (slice J21): a lane of mode local with yolo on goes from the landing check to main with no word recorded,
#    no waiver file and no release word: it lands, goes live, is published and merged on the answer given at `gated`.
# T6 The same with yolo off: the lane waits at `gated` and nothing goes live or out; one word (merge=approved) lands it, and then
#    it reaches main with no second word.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

U=https://github.com/o/r/pull
RULE='owner-rule-5f0e638d'
ID=release-proj-trunk

world_with_release() {  # <name>
  release_world "$1"
  lane a1 released >/dev/null; trunk land a1 >/dev/null 2>&1 || fail "a1 must land"; trunk verify "$PROJ" >/dev/null 2>&1 || fail "a1 must verify"
  trunk word release "$PROJ" "ship a1" >/dev/null 2>&1 || fail "the release word must record"
}

# The release proof's receipt for the release head, as bin/jg-trunk-release-proof.sh publishes it; <at> is its epoch.
receipt() {  # <at>
  printf '{"schema":1,"task":"%s","mode":"local-trunk","spawn_gen":"","head":"%s","pr":"%s/1","verdict":"PASS","at":%s}\n' "$ID" "$(tip)" "$U" "$1" > "$HOME_D/state/$ID.run-receipt.json"
}
sweep_mog() {  # the registered check over the fixture home
  PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" JG_ROOT_OVERRIDE="$W/root" JG_STATE_OVERRIDE="$HOME_D/state" JG_DATA_OVERRIDE="$HOME_D/data" \
    JG_CONFIG_OVERRIDE="$HOME_D/config" JG_MOG_CHECKS_LINT="$W/checks-lint" JG_MOG_ALERT="$ROOT/bin/jg-alert.sh" JG_CHECK_TIMEOUT=60 \
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
  assert_contains "$(JG_HOME="$HOME_D" JG_STATE_OVERRIDE="$HOME_D/state" bash "$ROOT/bin/jg-alert.sh" list)" "slow-delivery--$ID" "T1: a merge 10 minutes after the proof must raise the slow-delivery alert"
  git -C "$PROJ" rev-parse --verify -q refs/heads/release/v2 >/dev/null || fail "T1: the next trunk must be cut in the same pass: $out"
  [ "$(cat "$HOME_D/state/trunk-branch-proj")" = release/v2 ] || fail "T1: the project must be on the next trunk"
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
  git -C "$PROJ" rev-parse --verify -q refs/heads/release/v2 >/dev/null && fail "T2: nothing may roll over before the merge"
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
  lane a2 second >/dev/null; trunk land a2 >/dev/null 2>&1 || fail "T4: a2 must land"; trunk verify "$PROJ" >/dev/null 2>&1 || fail "T4: a2 must verify"
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
# answered_world <name> <yolo>: the release world with one proved lane l1 of mode local and the given yolo, and a policy that makes
# the tick's go-live and publish steps due at once. No word of any kind is recorded.
answered_world() {
  release_world "$1"
  printf 'live-quiet-minutes=0\nrelease-after-commits=1\n' >> "$HOME_D/config/trunk-policy"
  lane l1 answered >/dev/null
  jg_write_meta "$HOME_D/state/l1.meta" "project=$PROJ" "mode=local" "yolo=$2" "branch=fm/l1" "worktree=$W/lanes/l1" "spawn_gen=g-l1"
}
# settle: wait for every detached job the tick started (landing, verify, go-live, publish)
settle() { local _; for _ in $(seq 1 150); do [ -z "$(jg_test_detached_alive)" ] && ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && return 0; sleep 0.2; done; fail "the tick's jobs must settle"; }
# reaches_main: the green pin is live, the release is published and merged into main, with no word anywhere
reaches_main() {  # <label>
  local out
  sweep >/dev/null; settle; trunk verify "$PROJ" >/dev/null 2>&1 || fail "$1: the landed lane must verify"
  rm -f "$HOME_D"/config/.publish-* "$HOME_D"/data/jg-trunk-landing/.publish-* 2>/dev/null || true
  sweep >/dev/null; settle
  [ -f "$HOME_D/state/$ID.meta" ] || fail "$1: the tick must publish the release with no word: $(tail -3 "$HOME_D/data/jg-trunk-landing/outbox" 2>/dev/null)"
  [ "$(cat "$W/live-moves" 2>/dev/null)" = "$(cat "$HOME_D/state/trunk-green-proj")" ] || fail "$1: the home must go live at the green pin with no word"
  grep -qxF "merge_rule=gated:$2" "$HOME_D/state/$ID.meta" || fail "$1: the release record must carry the answer given at gated: $(cat "$HOME_D/state/$ID.meta")"
  receipt "$(date +%s)"; out=$(sweep_mog)
  [ "$(merges)" = 1 ] || fail "$1: the green release must merge on that answer: $out"
  [ ! -e "$HOME_D"/state/trunk-word-in-use-proj ] && [ ! -e "$HOME_D"/state/trunk-word-release-proj ] && [ ! -e "$HOME_D/data/trunk-words.tsv" ] || fail "$1: no word may be recorded"
  [ ! -e "$HOME_D/config/trunk-live-waiver" ] && [ ! -e "$HOME_D/config/trunk-release-waiver" ] || fail "$1: no waiver may be written"
  # The release PR is the trunk itself going into main: the landed change is in what was pushed, and that PR was merged by the guarded path.
  git --git-dir="$W/origin.git" merge-base --is-ancestor "$(awk -F'\t' '$1 == "l1" { c = $3 } END { print c }' "$HOME_D/data/trunk-landings.tsv")" refs/heads/trunk || fail "$1: the landed change must be in the release"
  [ "$(cat "$W/pr-state-1")" = merged ] || fail "$1: the release PR must be merged into main"
}

test_yolo_on_reaches_main_with_no_word() {
  answered_world yoloon on
  reaches_main T5 yolo
  pass 'T5 yolo on: the change lands, goes live, is published and merged into main with no word recorded'
}

test_yolo_off_waits_at_gated_and_one_word_carries_it_to_main() {
  local out
  answered_world yolooff off
  out=$(sweep); settle
  git -C "$PROJ" log --format=%s trunk | grep -qx "ticket l1" && fail "T6: yolo off must wait at gated"
  assert_contains "$out" "waits for the captain's word" "T6: the wait names its reason"
  [ ! -e "$HOME_D/data/trunk-gated.tsv" ] || fail "T6: no answer is recorded before a word"
  trunk release "$PROJ" >/dev/null 2>&1 && fail "T6: nothing goes out before the word"
  printf 'merge=approved\n' >> "$HOME_D/state/l1.meta"
  reaches_main T6 word
  pass 'T6 yolo off: the change waits at gated; one word lands it and carries it to main with no second word'
}

test_a_green_open_release_is_not_pushed_into
test_yolo_on_reaches_main_with_no_word
test_yolo_off_waits_at_gated_and_one_word_carries_it_to_main
printf 'jg-trunk-release-merge-first: ok\n'
