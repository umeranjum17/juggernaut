#!/usr/bin/env bash
# Integration test for bin/jg-trunk-live-home.sh as `jg-trunk.sh live` runs it, on a project whose trunk
# branch is trunk-v3 (not the default "trunk").
#
# T1 A home that cannot move is recorded as hook-failed:<reason> in data/trunk-in-use.tsv and the reason is
#    printed on the live line, for a diverged, a dirty, a wrong-branch and a detached-ahead home; a clean
#    home that lacks the commit fetches it from the trunk branch and records "live".
# T2 A move whose ref update fails after the tree and index were already updated leaves the home clean at
#    the old commit (not "dirty working tree" on the next run), and the next run moves it.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The launcher may inject core.hooksPath through GIT_CONFIG_COUNT; a fixture repo must not run those hooks.
# (Lane jg-dzgb0 owns the shared helper for this class; replace this line with it once it lands.)
unset GIT_CONFIG_COUNT; for v in $(compgen -v | grep -E '^GIT_CONFIG_(KEY|VALUE)_'); do unset "$v"; done

TMP_ROOT=$(jg_test_tmproot jg-trunk-live-home)
GIT_ID=(-c user.name=t -c user.email=t@example.invalid)

# world <name>: sets W HOME_D PROJ HOMEC (a home checkout that runs the project) and C (a landed trunk-v3 commit).
world() {
  W="$TMP_ROOT/$1"; HOME_D="$W/home"; PROJ="$HOME_D/projects/proj"; HOMEC="$W/homecode"
  mkdir -p "$W/root" "$HOME_D/state" "$HOME_D/data" "$HOME_D/config"
  cp -r "$ROOT/bin" "$W/root/bin"; ln -s "$ROOT/core" "$W/root/core"; ln -s "$ROOT/policy" "$W/root/policy"
  # shellcheck disable=SC2016 # the stub body is written verbatim
  printf '#!/usr/bin/env bash\ncase "$1" in blocking) exit 1 ;; *) exit 0 ;; esac\n' > "$W/root/bin/jg-captain-hold.sh"
  chmod +x "$W/root/bin/jg-captain-hold.sh"
  printf 'trunk-branch=trunk-v3\n' > "$HOME_D/config/trunk-policy"
  printf -- '- proj [local-trunk] - fixture project in local-trunk mode (added 2026-11-07)\n' > "$HOME_D/data/projects.md"
  jg_git_init_commit "$PROJ"
  printf 'data/\n' > "$PROJ/.gitignore"; git -C "$PROJ" add .gitignore; git -C "$PROJ" "${GIT_ID[@]}" commit -q -m gitignore
  jg_git_add_origin "$PROJ" "$W/origin.git"
  trunk init "$PROJ" >/dev/null 2>&1 || fail "trunk init must work"
  git clone -q "$(git -C "$PROJ" remote get-url origin)" "$HOMEC"
  # `live` moves the whole fleet from the tip's own tools (ap-t2); this file proves the single-home hook and go_live's record of it.
  printf '#!/usr/bin/env bash\nexec "%s/root/bin/jg-trunk-live-home.sh" "$@"\n' "$W" > "$HOME_D/config/live-hook.proj"; chmod +x "$HOME_D/config/live-hook.proj"
}

trunk() { JG_HOME="$HOME_D" JG_ROOT_OVERRIDE="$HOMEC" JG_STATE_OVERRIDE="$HOME_D/state" \
  JG_DATA_OVERRIDE="$HOME_D/data" JG_CONFIG_OVERRIDE="$HOME_D/config" "$W/root/bin/jg-trunk.sh" "$@"; }

# land_on_trunk <content>: one more commit on the trunk branch, recorded as green with the captain's word.
land_on_trunk() {
  local br
  br=$(cat "$HOME_D/state/trunk-branch-proj" 2>/dev/null || echo trunk-v3)
  printf '%s\n' "$1" > "$PROJ/work.txt"
  git -C "$PROJ" add work.txt; git -C "$PROJ" "${GIT_ID[@]}" commit -q -m "ticket $1" 
  C=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$PROJ" reset -q --hard HEAD~1
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref "refs/heads/$br" "$C"
  printf '%s\n' "$C" > "$HOME_D/state/trunk-tip-proj"; printf '%s\n' "$C" > "$HOME_D/state/trunk-green-proj"
  trunk word in-use "$PROJ" "go" >/dev/null 2>&1 || fail "the word must record"
}

# live_fails <reason-fragment>: live exits 3, prints the reason, and the record carries hook-failed:<reason>.
live_fails() {
  local out rc=0 row
  out=$(trunk live "$PROJ" 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "a home that did not move must exit 3, got $rc: $out"
  assert_contains "$out" "$1" "the live line must print the reason"
  row=$(tail -1 "$HOME_D/data/trunk-in-use.tsv")
  assert_contains "$row" "hook-failed:" "the record must carry hook-failed:<reason>"
  assert_contains "$row" "$1" "the record must carry the reason"
  case $row in *"hook-failed	"*|*"hook-failed") fail "the record must not be a bare hook-failed: $row" ;; esac
}

test_a_home_that_cannot_move_says_why() {
  world fail
  land_on_trunk one
  # diverged: the home holds a commit the trunk lacks
  printf 'mine\n' > "$HOMEC/mine.txt"; git -C "$HOMEC" add mine.txt; git -C "$HOMEC" "${GIT_ID[@]}" commit -q -m mine
  live_fails "diverged"
  git -C "$HOMEC" reset -q --hard origin/main
  # dirty
  trunk word in-use "$PROJ" "go" >/dev/null 2>&1
  printf 'dirty\n' >> "$HOMEC/README.md"
  live_fails "dirty working tree"
  git -C "$HOMEC" checkout -q -- README.md
  # wrong branch
  trunk word in-use "$PROJ" "go" >/dev/null 2>&1
  git -C "$HOMEC" checkout -q -b side
  live_fails "on side"
  git -C "$HOMEC" checkout -q main
  # detached ahead: a detached HEAD one commit past the trunk's parent that the trunk does not hold
  trunk word in-use "$PROJ" "go" >/dev/null 2>&1
  git -C "$HOMEC" checkout -q --detach
  printf 'ahead\n' > "$HOMEC/ahead.txt"; git -C "$HOMEC" add ahead.txt; git -C "$HOMEC" "${GIT_ID[@]}" commit -q -m ahead
  live_fails "diverged"
  pass 'a diverged, dirty, wrong-branch and detached-ahead home each record hook-failed:<reason> and print it'
}

test_a_clean_home_fetches_from_the_trunk_branch_and_goes_live() {
  local out
  world clean
  land_on_trunk two
  git -C "$HOMEC" cat-file -e "$C^{commit}" 2>/dev/null && fail "fixture: the home must not yet hold the landed commit"
  out=$(trunk live "$PROJ" 2>&1) || fail "a clean home must go live: $out"
  [ "$(git -C "$HOMEC" rev-parse HEAD)" = "$C" ] || fail "the home must be fast-forwarded to the landed commit: $out"
  assert_contains "$out" "$C" "live must name the exact commit"
  grep -Eq "^proj	$C	[0-9]+	live$" "$HOME_D/data/trunk-in-use.tsv" || fail "the record must say live"
  pass 'a clean home fetches the commit from the project trunk branch and records live'
}

test_a_failed_ref_update_leaves_the_home_clean_at_the_old_commit() {
  local old out hook
  world refail
  land_on_trunk three
  old=$(git -C "$HOMEC" rev-parse HEAD)
  "$W/root/bin/jg-home-guard.sh" install "$HOMEC" --tip "$old" >/dev/null || fail "install guard"
  hook="$HOMEC/.git/hooks/reference-transaction.chained"
  git -C "$HOMEC" fetch -q "$PROJ" refs/heads/trunk-v3 || fail "fixture: the home must hold the commit before the hook blocks ref updates"
  # shellcheck disable=SC2016 # the hook body is written verbatim
  printf '#!/bin/sh\n# git updates the tree and index before it prepares the branch ref, so failing there is the half-done move\nif [ "$1" = prepared ] && grep -q " refs/heads/"; then exit 1; fi\nexit 0\n' > "$hook"; chmod +x "$hook"
  live_fails "fast-forward failed"
  [ "$(git -C "$HOMEC" rev-parse HEAD)" = "$old" ] || fail "HEAD must stay at the old commit"
  [ "$(cat "$HOMEC/.git/jg-home-guard/trunk-tip")" = "$old" ] || fail "guard tip must stay at the old commit"
  [ -z "$(git -C "$HOMEC" status --porcelain)" ] || fail "index and tree must be back at the old commit: $(git -C "$HOMEC" status --porcelain)"
  rm -f "$hook"
  trunk word in-use "$PROJ" "go" >/dev/null 2>&1
  out=$(trunk live "$PROJ" 2>&1) || fail "the next run must move the home: $out"
  [ "$(git -C "$HOMEC" rev-parse HEAD)" = "$C" ] || fail "the next run must reach the landed commit: $out"
  [ -z "$(git -C "$HOMEC" status --porcelain)" ] || fail "the moved home must be clean"
  pass 'a failed ref update rolls index and tree back to the old commit, and the next run moves the home'
}

test_guarded_home_moves_with_its_recorded_tip() {
  local old out
  world guarded
  old=$(git -C "$HOMEC" rev-parse HEAD)
  "$W/root/bin/jg-home-guard.sh" install "$HOMEC" --tip "$old" >/dev/null || fail "install guard"
  land_on_trunk guarded
  out=$(trunk live "$PROJ" 2>&1) || fail "guarded home must go live: $out"
  [ "$(git -C "$HOMEC" rev-parse HEAD)" = "$C" ] || fail "guarded HEAD must advance"
  [ "$(cat "$HOMEC/.git/jg-home-guard/trunk-tip")" = "$C" ] || fail "guard tip must advance"
  [ -z "$(git -C "$HOMEC" status --porcelain)" ] || fail "guarded home must stay clean"
  pass 'live advances a guarded home and its recorded tip together'
}

test_the_stray_pool_gitignore_line_is_cleared_and_other_edits_are_kept() {
  local out stray=/.treehouse-pool/.treehouse
  world stray
  land_on_trunk four
  printf '%s\n' "$stray" >> "$HOMEC/.gitignore"
  out=$(trunk live "$PROJ" 2>&1) || fail "a home with only the stray pool line must go live: $out"
  [ "$(git -C "$HOMEC" rev-parse HEAD)" = "$C" ] || fail "the home must reach the landed commit: $out"
  grep -qxF "$stray" "$HOMEC/.gitignore" && fail "the stray line must be gone"
  [ -z "$(git -C "$HOMEC" status --porcelain)" ] || fail "the moved home must be clean"
  world strayplus
  land_on_trunk five
  printf '%s\n' "$stray" 'mine-local' >> "$HOMEC/.gitignore"
  live_fails "dirty working tree"
  out=$(trunk live "$PROJ" 2>&1 || true)
  assert_contains "$out" "dirty path: .gitignore" "the kept edit must be reported"
  grep -qxF mine-local "$HOMEC/.gitignore" || fail "the other edit must be kept"
  grep -qxF "$stray" "$HOMEC/.gitignore" && fail "the stray line must still be removed"
  pass 'live clears only the stray pool gitignore line, and keeps and reports any other edit'
}

# A home left half-moved to an EARLIER go-live target (index and tree equal that commit, HEAD still behind, the ref update refused)
# is adopted at that commit and carried to the new target. A home whose index matches no trunk commit, or that holds an extra
# untracked file, keeps the dirty refusal and loses nothing.
test_a_home_half_moved_to_an_earlier_target_finishes() {
  local c1 out
  world halfmoved
  land_on_trunk first
  c1=$C
  git -C "$HOMEC" fetch -q "$PROJ" refs/heads/trunk-v3 || fail "fixture: fetch the earlier target"
  git -C "$HOMEC" read-tree -u -m HEAD "$c1" || fail "fixture: cannot stage the earlier target"
  [ "$(git -C "$HOMEC" write-tree)" = "$(git -C "$PROJ" rev-parse "$c1^{tree}")" ] || fail "fixture: index must equal the earlier target tree"
  git -C "$PROJ" reset -q --hard "$c1"; land_on_trunk second
  out=$(trunk live "$PROJ" 2>&1) || fail "a half-moved home must go live: $out"
  [ "$(git -C "$HOMEC" rev-parse HEAD)" = "$C" ] || fail "the home must reach the new target: $out"
  [ -z "$(git -C "$HOMEC" status --porcelain)" ] || fail "the moved home must be clean"
  world halfmovedmine
  land_on_trunk first
  c1=$C
  git -C "$HOMEC" fetch -q "$PROJ" refs/heads/trunk-v3
  git -C "$HOMEC" read-tree -u -m HEAD "$c1"
  printf 'mine\n' > "$HOMEC/note.txt"
  git -C "$PROJ" reset -q --hard "$c1"; land_on_trunk second
  live_fails "dirty working tree"
  [ -f "$HOMEC/note.txt" ] || fail "the untracked file must be kept"
  world halfmovedodd
  land_on_trunk first
  c1=$C
  git -C "$HOMEC" fetch -q "$PROJ" refs/heads/trunk-v3
  git -C "$HOMEC" read-tree -u -m HEAD "$c1"
  printf 'edit\n' >> "$HOMEC/work.txt"
  git -C "$PROJ" reset -q --hard "$c1"; land_on_trunk second
  live_fails "dirty working tree"
  grep -qx edit "$HOMEC/work.txt" || fail "the edit must be kept"
  [ "$(git -C "$HOMEC" rev-parse HEAD)" != "$C" ] || fail "an index matching no trunk commit must not move"
  pass 'a home half-moved to an earlier target finishes; an extra file or an edit keeps the refusal and loses nothing'
}

test_guarded_home_moves_with_its_recorded_tip
test_a_home_half_moved_to_an_earlier_target_finishes
test_the_stray_pool_gitignore_line_is_cleared_and_other_edits_are_kept
test_a_home_that_cannot_move_says_why
test_a_failed_ref_update_leaves_the_home_clean_at_the_old_commit
test_a_clean_home_fetches_from_the_trunk_branch_and_goes_live
printf 'jg-trunk-live-home: ok\n'
