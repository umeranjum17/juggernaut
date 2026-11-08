#!/usr/bin/env bash
# Integration test for bin/jg-trunk-live-home.sh as `jg-trunk.sh live` runs it, on a project whose trunk
# branch is trunk-v3 (not the default "trunk").
#
# T1 A home that cannot move is recorded as hook-failed:<reason> in data/trunk-live.tsv and the reason is
#    printed on the live line, for a diverged, a dirty, a wrong-branch and a detached-ahead home; a clean
#    home that lacks the commit fetches it from the trunk branch and records "live".
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
  jg_git_init_commit "$PROJ"; jg_git_add_origin "$PROJ" "$W/origin.git"
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
  trunk word live "$PROJ" "go" >/dev/null 2>&1 || fail "the word must record"
}

# live_fails <reason-fragment>: live exits 3, prints the reason, and the record carries hook-failed:<reason>.
live_fails() {
  local out rc=0 row
  out=$(trunk live "$PROJ" 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "a home that did not move must exit 3, got $rc: $out"
  assert_contains "$out" "$1" "the live line must print the reason"
  row=$(tail -1 "$HOME_D/data/trunk-live.tsv")
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
  trunk word live "$PROJ" "go" >/dev/null 2>&1
  printf 'dirty\n' >> "$HOMEC/README.md"
  live_fails "dirty working tree"
  git -C "$HOMEC" checkout -q -- README.md
  # wrong branch
  trunk word live "$PROJ" "go" >/dev/null 2>&1
  git -C "$HOMEC" checkout -q -b side
  live_fails "on side"
  git -C "$HOMEC" checkout -q main
  # detached ahead: a detached HEAD one commit past the trunk's parent that the trunk does not hold
  trunk word live "$PROJ" "go" >/dev/null 2>&1
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
  grep -Eq "^proj	$C	[0-9]+	live$" "$HOME_D/data/trunk-live.tsv" || fail "the record must say live"
  pass 'a clean home fetches the commit from the project trunk branch and records live'
}

test_a_home_that_cannot_move_says_why
test_a_clean_home_fetches_from_the_trunk_branch_and_goes_live
printf 'jg-trunk-live-home: ok\n'
