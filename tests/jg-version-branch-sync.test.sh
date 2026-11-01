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
# T6 The project's current version branch is the newest release/c-<N> in its own
#    refs, compared as a number, and a project with none resolves to nothing.
# T7 The features pass carries the released version branch into an open feature
#    pull request as a merge commit that keeps the feature's own work, and a
#    second pass changes nothing.
# T8 A merge that was not the release pull request is silent, because the pass
#    runs after every recorded merge.
# T9 A feature branch whose merge conflicts is reported and left exactly as it
#    is; nothing is forced.
# T10 The recorded release merge runs the features pass itself, so no home needs
#    an editable hook for it.
# T11 A ship brief scaffolded with a project directory records that project's
#    version branch as its base, and the spawn with no --base-branch lands the
#    copy there; a brief that records no base is refused by name.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SYNC="$ROOT/bin/jg-version-branch-sync.sh"
OUTCOME_LIB="$ROOT/bin/jg-merge-outcome-lib.sh"
VERSION_LIB="$ROOT/bin/jg-version-branch-lib.sh"

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

# Cut a feature branch from the version branch and push it, leaving the seed
# clone back on the default branch.
add_feature_branch() {  # <world> <branch> <file>
  local w=$1 branch=$2 file=$3
  git -C "$w/seed" checkout -q -B "$branch" origin/release/c-1
  printf '%s\n' "$branch" > "$w/seed/$file"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "feature work on $branch"
  git -C "$w/seed" push -q origin "$branch"
  git -C "$w/seed" checkout -q main
}

# Land work on the version branch, then merge it into the default branch the way
# the release pull request does, and refresh the copy's origin refs.
release_lands() {  # <world> <file>
  local w=$1 file=$2
  git -C "$w/seed" checkout -q -B release/c-1 origin/release/c-1
  printf 'release\n' > "$w/seed/$file"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "release work"
  git -C "$w/seed" push -q origin HEAD:refs/heads/release/c-1
  git -C "$w/seed" checkout -q main
  git -C "$w/seed" merge -q --no-ff -m 'merge release/c-1 into main' release/c-1
  git -C "$w/seed" push -q origin main
  git -C "$w/copy" fetch -q --prune origin
}

# The features pass makes exactly two forge reads: the merged pull request's base
# and head, and the open pull requests that target the version branch. Each case
# writes both answers to files, so no test reaches the network.
make_features_gh() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/gh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pr view") cat "$FAKE_GH_VIEW"; exit 0 ;;
  "pr list") cat "$FAKE_GH_LIST"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$dir/gh"
  printf '%s\n' "$dir"
}

features_run() {  # <world> <view-file> <list-file> [<repo-dir>]
  local w=$1 view=$2 list=$3 repo=${4:-}
  [ -n "$repo" ] || repo=$w/copy
  PATH="$w/fake:$PATH" FAKE_GH_VIEW=$view FAKE_GH_LIST=$list \
    JG_HOME="$w/home" "$SYNC" features https://github.com/o/r/pull/1 "$repo" 2>&1
}

test_current_version_branch_is_the_newest() {
  local w out rc
  w=$(new_world t6)
  git -C "$w/seed" branch -q release/c-2 main
  git -C "$w/seed" branch -q release/c-10 main
  git -C "$w/seed" branch -q release/hotfix main
  out=$(cd "$w/seed" && bash -c '. "$1"; jg_current_version_branch .' _ "$VERSION_LIB" 2>&1)
  assert_equals release/c-10 "$out" "the newest release branch, compared as a number, is the current one"

  mkdir -p "$w/plain"
  git -C "$w/plain" init -q -b main
  out=$(cd "$w/plain" && bash -c '. "$1"; jg_current_version_branch .' _ "$VERSION_LIB" 2>&1)
  rc=$?
  assert_equals "" "$out" "a project with no release branch resolves to nothing"
  [ "$rc" -ne 0 ] || fail "a project with no release branch must report that it has none"
  out=$(cd "$w" && bash -c '. "$1"; jg_current_version_branch "$2"' _ "$VERSION_LIB" "$w/not-a-repo" 2>&1)
  rc=$?
  assert_equals "" "$out" "a directory that is not a checkout resolves to nothing"
  [ "$rc" -ne 0 ] || fail "a non-checkout must report that it has no version branch"
  pass "T6 the current version branch is the newest release/c-<N>";
}

test_features_carries_the_release_into_a_feature_branch() {
  local w release_tip feature_tip main_tip parents out
  w=$(new_world t7)
  make_features_gh "$w/fake" >/dev/null
  add_feature_branch "$w" fm/x feature.txt
  feature_tip=$(git -C "$w/seed" rev-parse fm/x)
  release_lands "$w" release.txt
  release_tip=$(git -C "$w/seed" rev-parse release/c-1)
  main_tip=$(remote_tip "$w" main)
  printf 'main\trelease/c-1\n' > "$w/view"
  printf '7\tfm/x\tfalse\n' > "$w/list"

  out=$(features_run "$w" "$w/view" "$w/list")
  assert_contains "$out" "fm/x: updated " "the feature branch is carried forward"
  git -C "$w/origin.git" merge-base --is-ancestor "$release_tip" fm/x \
    || fail "the released version branch is not in the feature branch"
  git -C "$w/origin.git" merge-base --is-ancestor "$feature_tip" fm/x \
    || fail "the carry dropped the feature branch's own work"
  parents=$(git -C "$w/origin.git" rev-list --parents -n 1 fm/x | cut -d' ' -f2- | wc -w | tr -d '[:space:]')
  assert_equals 2 "$parents" "the carry is a merge commit, not a rewrite"
  assert_equals "$main_tip" "$(remote_tip "$w" main)" "the default branch is untouched"

  out=$(features_run "$w" "$w/view" "$w/list")
  assert_contains "$out" "fm/x: already current" "a second pass changes nothing"
  pass "T7 the features pass carries the release into an open feature branch once"
}

test_non_release_merge_is_silent() {
  local w out before
  w=$(new_world t8)
  make_features_gh "$w/fake" >/dev/null
  add_feature_branch "$w" fm/x feature.txt
  release_lands "$w" release.txt
  before=$(remote_tip "$w" fm/x)
  printf 'release/c-1\tfm/x\n' > "$w/view"
  printf '7\tfm/x\tfalse\n' > "$w/list"

  out=$(features_run "$w" "$w/view" "$w/list")
  assert_equals "" "$out" "a merge that was not the release pull request is silent"
  assert_equals "$before" "$(remote_tip "$w" fm/x)" "a feature merge moves no feature branch"
  pass "T8 a merge that is not the release pull request is silent"
}

test_conflicting_feature_branch_is_left_alone() {
  local w out before
  w=$(new_world t9)
  make_features_gh "$w/fake" >/dev/null
  add_feature_branch "$w" fm/x shared.txt
  release_lands "$w" shared.txt
  before=$(remote_tip "$w" fm/x)
  printf 'main\trelease/c-1\n' > "$w/view"
  printf '7\tfm/x\tfalse\n' > "$w/list"

  out=$(features_run "$w" "$w/view" "$w/list")
  assert_contains "$out" "fm/x: skipped: merging release/c-1 conflicts" "a conflict is reported"
  assert_contains "$out" "left as it is" "the report says the branch is untouched"
  assert_equals "$before" "$(remote_tip "$w" fm/x)" "a conflicting branch is not forced"
  pass "T9 a feature branch whose merge conflicts is left exactly as it is"
}

test_recorded_release_merge_runs_the_features_pass() {
  local w out
  w=$(new_world t10)
  configure "$w"
  make_features_gh "$w/fake" >/dev/null
  add_feature_branch "$w" fm/x feature.txt
  release_lands "$w" release.txt
  printf 'main\trelease/c-1\n' > "$w/view"
  printf '7\tfm/x\tfalse\n' > "$w/list"
  mkdir -p "$w/home/state"
  printf 'project=%s\n' "$w/copy" > "$w/home/state/task-v2.meta"

  out=$(cd "$w/home" && PATH="$w/fake:$PATH" FAKE_GH_VIEW="$w/view" FAKE_GH_LIST="$w/list" \
    JG_HOME="$w/home" JG_STATE_OVERRIDE="$w/home/state" \
    JG_ROOT_OVERRIDE="$w/copy" JG_CONFIG_OVERRIDE="$w/home/config" bash -c '
      . "$1"
      jg_merge_outcome_report "$2" "$2/state" task-v2 \
        https://github.com/o/r/pull/1 self attended
    ' _ "$OUTCOME_LIB" "$w/home" 2>&1)
  assert_contains "$out" "features: fm/x: updated " \
    "recording the release merge runs the features pass itself"
  pass "T10 a recorded release merge runs the features pass with no other step"
}

test_spawn_and_brief_default_to_the_version_branch() {
  local w home proj wt fakebin out status brief tip
  w=$(new_world t11)
  home="$w/home"
  proj="$w/proj"
  wt="$w/wt"
  jg_test_spawn_home "$home"
  git clone -q "$w/origin.git" "$proj" 2>/dev/null
  git -C "$proj" remote set-head origin main >/dev/null 2>&1 || true
  # A real scaffold, so the default is proven on the brief the spawn then reads.
  JG_HOME="$home" "$ROOT/bin/jg-brief.sh" t11 proj --mode direct-PR --project "$proj" >/dev/null 2>&1 \
    || fail "jg-brief.sh with a project directory did not scaffold"
  brief="$home/data/t11/brief.md"
  awk '{ gsub(/\{TASK\}/, "Ship the version-branch default."); gsub(/\{JUGGERNAUT_SPEC\}/, "Exercise the default base end to end."); print }' \
    "$brief" > "$brief.filled" || fail "could not fill the scaffolded brief"
  mv "$brief.filled" "$brief" || fail "could not fill the scaffolded brief"
  assert_grep 'Base branch: release/c-1' "$brief" \
    "the brief did not record the project's version branch as its base"

  # An isolated copy of the project at its default branch, which the spawn must
  # move to the version branch because no base flag is passed.
  git -C "$proj" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 \
    || fail "could not prepare the isolated worktree"
  fakebin=$(make_spawn_fakebin "$w/fake-spawn")
  jg_test_fake_sleep_noop "$fakebin"
  out=$(jg_test_run_spawn "$home" "$wt" "$fakebin" \
    t11 "$proj" codex --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "a ship spawn with no --base-branch should launch: $out"
  assert_grep 'base_branch=release/c-1' "$home/state/t11.meta" \
    "the spawned task did not record the version branch as its base"
  tip=$(git -C "$proj" rev-parse origin/release/c-1)
  assert_equals "$tip" "$(git -C "$wt" rev-parse HEAD)" \
    "the copy did not start from the version branch"

  # The other half: a brief that records no base is refused by name rather than
  # launched onto the default branch.
  jg_test_spawn_brief "$home" t12
  out=$(jg_test_run_spawn "$home" "$wt" "$fakebin" \
    t12 "$proj" codex --mode direct-PR --yolo off)
  status=$?
  expect_code 1 "$status" "a brief with no base on a version-branch project should be refused"
  assert_contains "$out" "release/c-1" "the refusal does not name the version branch"
  pass "T11 the spawn and the brief default to the project's version branch"
}

test_behind_is_carried_forward
test_diverged_is_reported_not_forced
test_dirty_copy_is_skipped
test_recorded_merge_carries_the_branch
test_unconfigured_home_is_silent
test_current_version_branch_is_the_newest
test_features_carries_the_release_into_a_feature_branch
test_non_release_merge_is_silent
test_conflicting_feature_branch_is_left_alone
test_recorded_release_merge_runs_the_features_pass
test_spawn_and_brief_default_to_the_version_branch
echo "all jg-version-branch-sync tests passed"
