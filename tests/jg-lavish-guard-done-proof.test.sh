#!/usr/bin/env bash
# Integration test for the done proof check of bin/jg-lavish-guard.sh --append: a local-trunk lane's worker cannot write
# `done` while the landing would refuse its head for missing proof (jg_dod_trunk_proof_gaps), sees the gap list at once,
# also after a conflict fix, and its status file is left unchanged.
# Built from the real failure of opp-c1-checks-writer on 9 Nov: it wrote done with a PASS receipt and no sealed run
# evidence the landing would accept, and learned it only from the landing's refusal; after the rebase its new head
# 1581b9add had neither receipt nor merge-card ("proof inputs are incomplete: no completion receipt with verdict PASS for
# head 1581b9add439 ...;no approved merge-card evidence citing files for head 1581b9add439 ..."), and it landed 53 minutes
# after its first done.
# Each case pipes the line through the status command the generated brief gives a worker (bin/jg-brief.sh), with no
# JG_HOME, into a fixture home of tests/jg-trunk-fixture.sh (real git, the real merge-card check, a sealed run record).
#
# D1 A lane with a PASS receipt and no sealed run: done is refused with exit 1 and the merge-card gap, the status file is
#    unchanged, and a blocked: line still goes through.
# D2 With the whole proof the done line is written; after a conflict fix changes the lane's commit on a moved tip, done
#    is refused naming the receipt and merge-card gaps of the new head, and is written again once that head is proved.
#    (A rebase with no change keeps its proof; that case is tests/jg-trunk-proof-same-change.test.sh's.)
# D4 A lane with the whole proof whose changed file the landing's lint (gate-lint) would refuse: done is refused with the
#    lint named, the status file is unchanged (the landing's gate-failure return, found in the lane); once the finding is fixed
#    and the head is proved again, done is written. The lint the landing runs is the lint the done runs.
# (D4 is jg_dod_trunk_lint_gap in bin/jg-merge-gate-lib.sh, run by the guard.)
# D3 A check that cannot run lets the line through with one warning: no lane record, no jq, another delivery mode.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

SEED=opp-c1-checks-writer

# bare_lane <id> [<mode>]: a lane off the trunk tip with one commit and its lane record, and no proof yet.
bare_lane() {
  local id=$1 wt="$W/lanes/$1"
  git -C "$PROJ" worktree add -q -b "fm/$id" "$wt" trunk
  commit_in "$wt" "$id.txt" "$id" "ticket $id"
  jg_write_meta "$HOME_D/state/$id.meta" "project=$PROJ" "mode=${2:-local-trunk}" "branch=fm/$id" "worktree=$wt" "spawn_gen=g-$id"
}
# append <id> <line> [<PATH>]: the worker's status command; sets RC and ERR (its stderr).
append() {
  RC=0
  printf '%s\n' "$2" | env -u JG_HOME -u JG_STATE_OVERRIDE -u JG_DATA_OVERRIDE PATH="${3:-$PATH}" \
    "$W/root/bin/jg-lavish-guard.sh" --append "$HOME_D/state/$1.status" 2>"$W/err" || RC=$?
  ERR=$(cat "$W/err")
}
head12() { git -C "$W/lanes/$1" rev-parse HEAD | cut -c1-12; }

test_a_done_with_no_sealed_run_is_refused_and_the_status_file_is_unchanged() {
  local before h
  world d1; bare_lane "$SEED"; prove_part "$SEED" receipt; h=$(head12 "$SEED")
  append "$SEED" 'working [at=1794240000]: Checks block written from the sealed run'
  [ "$RC" = 0 ] && [ -z "$ERR" ] || fail "a working line must pass with no word: rc=$RC $ERR"
  before=$(cat "$HOME_D/state/$SEED.status")
  append "$SEED" "done [at=1794243000]: ready in branch fm/$SEED (local-trunk)"
  [ "$RC" = 1 ] || fail "a done with no sealed run must exit 1, got $RC: $ERR"
  assert_contains "$ERR" "no sealed clean done-done run at head $h of $SEED" "the refusal names the missing sealed run at the head"
  assert_not_contains "$ERR" "no completion receipt" "the PASS receipt at this head is not a gap"
  assert_contains "$ERR" "blocked:" "the refusal says what to write when the proof cannot be finished"
  [ "$(cat "$HOME_D/state/$SEED.status")" = "$before" ] || fail "a refused done must leave the status file unchanged: $(cat "$HOME_D/state/$SEED.status")"
  append "$SEED" 'blocked [at=1794243100]: the sealed run cannot be written'
  [ "$RC" = 0 ] || fail "a blocked line must go through: $ERR"
  assert_contains "$(tail -n 1 "$HOME_D/state/$SEED.status")" "blocked [at=1794243100]" "the blocked line is written"
  pass 'a done with no sealed run exits 1 with the gap and an unchanged status file; blocked: still goes through'
}

test_a_proved_done_is_written_and_a_conflict_fix_must_prove_its_new_head() {
  local done_line h before
  world d2; bare_lane "$SEED"; prove "$SEED"
  done_line="done [at=1794243000]: ready in branch fm/$SEED (local-trunk)"
  append "$SEED" "$done_line"
  [ "$RC" = 0 ] && [ -z "$ERR" ] || fail "a done with the whole proof must be written with no word: rc=$RC $ERR"
  [ "$(tail -n 1 "$HOME_D/state/$SEED.status")" = "$done_line" ] || fail "the done line must be written unchanged"
  # The conflict fix: the tip moved and adds the lane's own file, so the rebase stops on a conflict and the worker
  # resolves it. The lane's change is now another change (a rebase with no change keeps its proof), so its proof is not kept.
  git -C "$PROJ" worktree add -q -b tipwork "$W/tip" trunk; commit_in "$W/tip" "$SEED.txt" "tip line" "ticket tip"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/tip" rev-parse HEAD)" || fail "the fixture tip must move"
  git -C "$W/lanes/$SEED" -c user.name=t -c user.email=t@example.invalid rebase -q trunk >/dev/null 2>&1 \
    && fail "the fixture rebase must stop on a conflict"
  printf 'tip line\n%s\n' "$SEED" > "$W/lanes/$SEED/$SEED.txt"; git -C "$W/lanes/$SEED" add "$SEED.txt"
  GIT_EDITOR=true git -C "$W/lanes/$SEED" -c user.name=t -c user.email=t@example.invalid rebase --continue >/dev/null 2>&1 \
    || fail "the conflict fix must complete the rebase"
  [ "$(git -C "$W/lanes/$SEED" rev-parse HEAD^)" = "$(git -C "$PROJ" rev-parse trunk)" ] || fail "the fixed lane must be one commit on the moved tip"
  h=$(head12 "$SEED"); before=$(cat "$HOME_D/state/$SEED.status")
  append "$SEED" "done [at=1794244000]: conflict fixed; ready in branch fm/$SEED (local-trunk)"
  [ "$RC" = 1 ] || fail "a done after a conflict fix with no new proof must exit 1, got $RC: $ERR"
  assert_contains "$ERR" "no completion receipt with verdict PASS for head $h of $SEED" "the receipt gap of the new head is named"
  assert_contains "$ERR" "no sealed clean done-done run at head $h of $SEED" "the sealed-run gap of the new head is named"
  [ "$(cat "$HOME_D/state/$SEED.status")" = "$before" ] || fail "the refused done must leave the status file unchanged"
  prove "$SEED"
  append "$SEED" "done [at=1794245000]: conflict fixed; ready in branch fm/$SEED (local-trunk)"
  [ "$RC" = 0 ] && [ -z "$ERR" ] || fail "the proved new head must be written: rc=$RC $ERR"
  assert_contains "$(tail -n 1 "$HOME_D/state/$SEED.status")" "done [at=1794245000]" "the new done line is written"
  pass 'a proved done is written; after a conflict fix the new head is refused with every gap until it is proved'
}

test_a_check_that_cannot_run_lets_the_line_through_with_a_warning() {
  local nojq
  world d3; bare_lane "$SEED"; bare_lane pr-lane direct-PR
  append unrecorded 'done [at=1]: ready'
  [ "$RC" = 0 ] || fail "a done with no lane record must go through: $ERR"
  assert_contains "$ERR" "warning: the proof of unrecorded was not checked before this done: no lane record" "no lane record is warned"
  assert_grep 'done [at=1]: ready' "$HOME_D/state/unrecorded.status" "the line with no lane record is written"
  nojq=$(jg_test_base_path_sans "$PATH" jq)
  append "$SEED" "done [at=2]: ready in branch fm/$SEED (local-trunk)" "$nojq"
  [ "$RC" = 0 ] || fail "a done that cannot be checked for want of jq must go through: $ERR"
  assert_contains "$ERR" "was not checked before this done: jq is not installed" "no jq is warned"
  assert_grep 'done [at=2]' "$HOME_D/state/$SEED.status" "the line checked without jq is written"
  append pr-lane 'done [at=3]: PR https://github.com/o/r/pull/9 checks green'
  [ "$RC" = 0 ] || fail "a done of another delivery mode must go through: $ERR"
  assert_contains "$ERR" "it is a direct-PR lane, not a local-trunk one" "another delivery mode is warned"
  assert_grep 'done [at=3]' "$HOME_D/state/pr-lane.status" "the other mode's line is written"
  pass 'no lane record, no jq and another delivery mode each let the line through with one warning'
}

test_a_done_whose_lint_the_landing_would_refuse_is_refused_in_the_lane() {
  local wt h before
  world d4; bare_lane "$SEED"; wt="$W/lanes/$SEED"
  printf 'UGLY\n' >> "$wt/work.txt"; git -C "$wt" add work.txt
  git -C "$wt" -c user.name=t -c user.email=t@example.invalid commit -q --amend --no-edit
  prove "$SEED"; h=$(head12 "$SEED"); before=$(cat "$HOME_D/state/$SEED.status" 2>/dev/null)
  append "$SEED" "done [at=1794243000]: ready in branch fm/$SEED (local-trunk)"
  [ "$RC" = 1 ] || fail "a done the landing's lint would refuse must exit 1, got $RC: $ERR"
  assert_contains "$ERR" "the lint the landing runs" "the refusal names the lint"
  assert_contains "$ERR" "at head $h" "the refusal names the head"
  assert_not_contains "$ERR" "no completion receipt" "the whole proof is not a gap"
  [ "$(cat "$HOME_D/state/$SEED.status" 2>/dev/null)" = "$before" ] || fail "a refused done must leave the status file unchanged"
  git -C "$wt" reset -q --hard HEAD^ && git -C "$wt" status --porcelain | grep -q . && fail "the lane must be clean"
  commit_in "$wt" "$SEED.txt" "$SEED" "ticket $SEED"
  prove "$SEED"
  append "$SEED" "done [at=1794244000]: lint fixed; ready in branch fm/$SEED (local-trunk)"
  [ "$RC" = 0 ] && [ -z "$ERR" ] || fail "the fixed and proved head must be written: rc=$RC $ERR"
  pass 'a done whose lint the landing would refuse is refused in the lane; the fixed head is written'
}

test_a_done_with_no_sealed_run_is_refused_and_the_status_file_is_unchanged
test_a_done_whose_lint_the_landing_would_refuse_is_refused_in_the_lane
test_a_proved_done_is_written_and_a_conflict_fix_must_prove_its_new_head
test_a_check_that_cannot_run_lets_the_line_through_with_a_warning
printf 'jg-lavish-guard-done-proof: ok\n'
