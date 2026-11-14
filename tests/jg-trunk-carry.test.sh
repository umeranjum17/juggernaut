#!/usr/bin/env bash
# Integration test for the carry check of bin/jg-trunk.sh retire (ticket trunk-empty-commit-carry): what makes a commit of
# an old trunk "not carried" into the current trunk or the default branch. The release proof shares the check
# (bin/jg-trunk-carry-lib.sh); tests/jg-trunk-release-open-pr.test.sh runs it there.
#
# T1 A release merged by rebase (its commit has a new id on the default branch) whose old trunk ends in an empty commit
#    that the rebase dropped is cleaned up by retire: the empty commit has nothing to carry.
# T2 A commit of the old trunk that the current trunk holds by patch under another id is carried; retire cleans up.
# T3 A real hotfix on the old trunk is still not carried: retire keeps the branch and names the hotfix, with or
#    without an empty commit beside it.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# A released first trunk whose release pull request merged by rebase, then rolled over to release/v2. The old trunk `trunk`
# stays on disk, held by a clean worktree WT, so the case runs retire itself. Sets REL (the released
# head), WT and the default branch's rebased copy of the release (another id, the same patch).
rebased_world() {  # <name>
  local rebased
  world "$1"
  lane o1 one; trunk land o1 >/dev/null 2>&1 || fail "o1 must land"; trunk verify "$PROJ" >/dev/null 2>&1 || fail "o1 must verify"
  trunk word release "$PROJ" "ship it" >/dev/null 2>&1; trunk release "$PROJ" >/dev/null 2>&1 || fail "release must open"
  REL=$(tip); WT="$W/oldwt"
  git -C "$PROJ" fetch -q origin main
  rebased=$(git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit-tree "$REL^{tree}" -p origin/main -m "ticket o1 (rebased)")
  git -C "$PROJ" push -q origin "$rebased:refs/heads/main"
  printf 'merged\n' > "$W/pr-state"
  # Uncommitted work in the worktree keeps the old trunk through the rollover's own cleanup.
  git -C "$PROJ" worktree add -q "$WT" trunk; printf 'scratch\n' > "$WT/unsaved.txt"
  trunk rollover "$PROJ" >/dev/null 2>&1 || fail "the merged release must roll over"
  git -C "$PROJ" rev-parse --verify -q refs/heads/trunk >/dev/null || fail "fixture: the rollover must keep the old trunk"
  rm -f "$WT/unsaved.txt"
}

# The old trunk takes one more commit after the release (an empty one, or a real file), through its own worktree.
on_old_trunk() {  # <empty|file> <message>
  if [ "$1" = empty ]; then JG_TRUNK_WRITER=1 git -C "$WT" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "$2"
  else JG_TRUNK_WRITER=1 commit_in "$WT" hot.txt hotfix "$2"; fi
}

test_an_empty_commit_is_not_a_hotfix() {
  local out
  rebased_world empty
  on_old_trunk empty "ticket nothing: no change"
  out=$(trunk retire "$PROJ" 2>&1) || fail "T1: retire must not fail: $out"
  assert_contains "$out" "deleted local trunk" "T1: an old trunk ending in an empty commit must be cleaned up: $out"
  ! git -C "$PROJ" rev-parse --verify -q refs/heads/trunk >/dev/null || fail "T1: the old local trunk must be gone"
  pass 'T1 an old trunk whose release was rebase-merged and that ends in an empty commit is cleaned up'
}

test_a_patch_identical_commit_is_carried() {
  local out
  rebased_world same
  on_old_trunk file "ticket hx: a hotfix"
  # The current trunk holds the same patch under another id: a lane on release/v2 carries it.
  git -C "$PROJ" worktree add -q -b fm/hx2 "$W/lanes/hx2" release/v2
  git -C "$W/lanes/hx2" cherry-pick -n "$(git -C "$WT" rev-parse HEAD)" >/dev/null 2>&1 || fail "T2: the hotfix must cherry-pick"
  git -C "$W/lanes/hx2" -c user.name=t -c user.email=t@example.invalid commit -q -m "ticket hx2: carry hotfix hx"
  jg_write_meta "$HOME_D/state/hx2.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/hx2" "worktree=$W/lanes/hx2" "spawn_gen=g-hx2"; prove hx2
  trunk land hx2 >/dev/null 2>&1 || fail "T2: the carrying lane must land"
  out=$(trunk retire "$PROJ" 2>&1) || fail "T2: retire must not fail: $out"
  assert_contains "$out" "deleted local trunk" "T2: a patch-identical commit under another id is carried: $out"
  pass 'T2 a commit the current trunk holds by patch under another id is carried and the old trunk is cleaned up'
}

test_a_real_hotfix_is_still_not_carried() {
  local out
  rebased_world real
  on_old_trunk empty "ticket nothing: no change"
  on_old_trunk file "ticket hx: a real hotfix"
  out=$(trunk retire "$PROJ" 2>&1) || fail "T3: retire must not fail: $out"
  assert_contains "$out" "kept trunk: hotfix not carried into release/v2: " "T3: a real hotfix keeps the old trunk"
  assert_contains "$out" "ticket hx" "T3: the hotfix is named"
  assert_not_contains "$out" "ticket nothing" "T3: the empty commit is not named as a hotfix"
  git -C "$PROJ" rev-parse --verify -q refs/heads/trunk >/dev/null || fail "T3: the old trunk must not be deleted"
  pass 'T3 a real hotfix beside an empty commit still keeps the old trunk, and only the hotfix is named'
}

test_an_empty_commit_is_not_a_hotfix
test_a_patch_identical_commit_is_carried
test_a_real_hotfix_is_still_not_carried
printf 'jg-trunk-carry: ok\n'
