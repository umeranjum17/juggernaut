#!/usr/bin/env bash
# Fast eval for bin/jg-version-branch-sync.sh and the merge-outcome hook that
# runs it.
#
# T1 A version branch two merges behind the default branch is moved forward to
#    the default branch's tip, and the default branch is untouched.
# T2 A version branch carrying its own commit is reported as unable to
#    fast-forward and left exactly where it was; nothing is forced or merged.
# T3 A dirty copy is skipped as a dirty copy with its path named, and the version
#    branch does not move.
# T4 A recorded merge to the default branch moves the version branch with no
#    other step, because bin/jg-merge-outcome-lib.sh runs the pass itself.
# T5 No config/version-branch is silence, not an error, so an unconfigured home
#    is unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/jg-version-branch-sync.sh"
OUTCOME_LIB="$ROOT/bin/jg-merge-outcome-lib.sh"

jg_git_identity fmtest fmtest@example.com

TMP_ROOT=$(jg_test_tmproot jg-version-branch-sync-tests)

# A world is a bare origin, a seed clone that plays the forge, and a home whose
# checkout is the copy this pass acts from. The version branch starts where the
# default branch starts.
new_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  printf 'v1\n' > "$w/seed/AGENTS.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main
  git -C "$w/seed" push -q origin main:refs/heads/release/c-1
  git clone -q "$w/origin.git" "$w/copy"
  git -C "$w/copy" remote set-head origin main >/dev/null 2>&1 || true
  printf '%s\n' "$w"
}

# One more merge on the default branch, fetched into the copy so its origin refs
# are current while the version branch stays behind.
merge_once() {
  local w=$1
  printf 'm-%s\n' "$RANDOM$RANDOM" >> "$w/seed/README.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm merge
  git -C "$w/seed" push -q origin main
  git -C "$w/copy" fetch -q origin
}

configure() { printf 'release/c-1\n' > "$1/home/config/version-branch"; }

sync_run() { JG_ROOT_OVERRIDE="$1/copy" JG_HOME="$1/home" "$SYNC" run 2>&1; }

remote_tip() { git -C "$1/origin.git" rev-parse "refs/heads/$2"; }

test_behind_is_carried_forward() {
  local w out main_before
  w=$(new_world t1)
  configure "$w"
  merge_once "$w"
  merge_once "$w"
  main_before=$(remote_tip "$w" main)

  out=$(sync_run "$w")
  assert_contains "$out" "release/c-1: updated " "the version branch is carried forward"
  assert_equals "$main_before" "$(remote_tip "$w" release/c-1)" \
    "the version branch is the default branch's tip"
  assert_equals "$main_before" "$(remote_tip "$w" main)" "the default branch is untouched"

  out=$(sync_run "$w")
  assert_equals "release/c-1: already current" "$out" "a second pass is a no-op"
  pass "T1 a version branch behind the default branch is carried forward"
}

test_diverged_is_reported_not_forced() {
  local w out before
  w=$(new_world t2)
  configure "$w"
  git -C "$w/seed" checkout -q -b version-only
  printf 'own\n' > "$w/seed/version-only.txt"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "version branch own work"
  git -C "$w/seed" push -q origin HEAD:refs/heads/release/c-1
  git -C "$w/seed" checkout -q main
  merge_once "$w"
  before=$(remote_tip "$w" release/c-1)

  out=$(sync_run "$w")
  assert_contains "$out" "release/c-1: skipped: origin/main cannot fast-forward it" \
    "a divergence is reported"
  assert_contains "$out" "was left as it is" "the report says the branch is untouched"
  assert_equals "$before" "$(remote_tip "$w" release/c-1)" \
    "the version branch did not move and nothing was forced"
  pass "T2 a version branch that cannot fast-forward is reported, not forced"
}

test_dirty_copy_is_skipped() {
  local w out before
  w=$(new_world t3)
  configure "$w"
  merge_once "$w"
  before=$(remote_tip "$w" release/c-1)
  printf 'scratch\n' > "$w/copy/stray.txt"

  out=$(sync_run "$w")
  assert_contains "$out" "release/c-1: skipped: dirty working tree" "a dirty copy is refused"
  assert_contains "$out" "dirty path: stray.txt" "the dirty path is named"
  assert_equals "$before" "$(remote_tip "$w" release/c-1)" "a dirty copy moves nothing"
  pass "T3 a dirty copy is skipped and its path is named"
}

test_recorded_merge_carries_the_branch() {
  local w out main_before
  w=$(new_world t4)
  configure "$w"
  merge_once "$w"
  main_before=$(remote_tip "$w" main)
  # A main home records the merge through the shared operation, with no
  # version-branch step of its own anywhere in this test.
  out=$(cd "$w/home" && JG_HOME="$w/home" JG_STATE_OVERRIDE="$w/home/state" \
    JG_ROOT_OVERRIDE="$w/copy" JG_CONFIG_OVERRIDE="$w/home/config" bash -c '
      . "$1"
      jg_merge_outcome_report "$2" "$2/state" task-v1 \
        https://github.com/o/r/pull/1 self attended
    ' _ "$OUTCOME_LIB" "$w/home" 2>&1)
  assert_contains "$out" "release/c-1: updated " \
    "recording the merge runs the version-branch carry itself"
  assert_equals "$main_before" "$(remote_tip "$w" release/c-1)" \
    "the version branch carries the merge with no other step"
  pass "T4 a recorded merge carries the version branch with no human step"
}

test_unconfigured_home_is_silent() {
  local w out
  w=$(new_world t5)
  merge_once "$w"
  out=$(sync_run "$w")
  assert_equals "" "$out" "an unconfigured home prints nothing"
  pass "T5 a home with no version branch is silent"
}

test_behind_is_carried_forward
test_diverged_is_reported_not_forced
test_dirty_copy_is_skipped
test_recorded_merge_carries_the_branch
test_unconfigured_home_is_silent
echo "all jg-version-branch-sync tests passed"
