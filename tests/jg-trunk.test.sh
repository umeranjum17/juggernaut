#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh: the local trunk flow end to end against real git
# repositories, a local bare origin, the real gate chain and a stub for the captain-hold reader.
#
# T1 A one-commit lane lands on the trunk, is logged, runs the live hook at that commit, and
#    the trunk moves by compare-and-swap.
# T2 Every unsafe landing refuses and leaves the trunk where it was: a second commit, a moved
#    tip, a failing gate, a red trunk, away mode, a ref a lane moved, a decision still open on
#    linked work, and a protected path.
# T3 The seams are the only place behaviour changes: protected-landing=gate and away-landing=allowed
#    let the same commits land, with no code change.
# T4 A smoke landing is pinned behind: the home does not move until verify passes, and a red
#    verify stops landings except a fixes-red commit.
# T5 The batch release pushes the trunk to the next release branch without force and opens one
#    PR listing every commit; an empty batch, a red trunk and an unverified tip refuse.
# The done-done journey journeys/trunk-landing.sh runs this file and seals its output.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-trunk)

# A world: a copied bin (with a stub hold reader), a home, a project with a local bare origin
# and an initialised trunk, a recording live hook and a fake gh-axi.
world() {  # <name>: sets W HOME_D PROJ
  W="$TMP_ROOT/$1"; HOME_D="$W/home"; PROJ="$HOME_D/projects/proj"
  mkdir -p "$W/root" "$HOME_D/state" "$HOME_D/data" "$HOME_D/config" "$W/fakebin"
  cp -r "$ROOT/bin" "$W/root/bin"
  ln -s "$ROOT/core" "$W/root/core"; ln -s "$ROOT/policy" "$W/root/policy"
  cat > "$W/root/bin/jg-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  open) exit 1 ;;
  blocking) [ -f "$JG_STATE_OVERRIDE/linked-open" ] && { printf 'ticket-x\n'; exit 0; }; exit 1 ;;
esac
SH
  cat > "$W/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/gh-calls"
printf 'https://github.com/o/r/pull/9\n'
SH
  cat > "$HOME_D/config/live-hook.proj" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$2" >> "$W/live-moves"
SH
  chmod +x "$W/root/bin/jg-captain-hold.sh" "$W/fakebin/gh-axi" "$HOME_D/config/live-hook.proj"
  printf 'gate-full=! grep -q BAD work.txt\n' > "$HOME_D/config/trunk-policy"
  jg_git_init_commit "$PROJ"; jg_git_add_origin "$PROJ" "$W/origin.git"
  git -C "$PROJ" branch release/c-4
  trunk init "$PROJ" >/dev/null || fail "trunk init must work"
}

trunk() { PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" JG_ROOT_OVERRIDE="${CODE_ROOT:-$W/root}" JG_STATE_OVERRIDE="$HOME_D/state" \
  JG_DATA_OVERRIDE="$HOME_D/data" JG_CONFIG_OVERRIDE="$HOME_D/config" "$W/root/bin/jg-trunk.sh" "$@"; }

commit_in() {  # <worktree> <file> <content> <message> [<note>]
  mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; git -C "$1" add "$2"
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m "$4" ${5:+-m "$5"}
}
# lane <id> <content> [<file>] [<note>]: a lane off the trunk tip with one commit.
lane() {
  local id=$1 wt="$W/lanes/$1"
  git -C "$PROJ" worktree add -q -b "fm/$id" "$wt" trunk
  commit_in "$wt" "${3:-work.txt}" "$2" "ticket $id" "${4-}"
  jg_write_meta "$HOME_D/state/$id.meta" "project=$PROJ" "mode=trunk" "branch=fm/$id" "worktree=$wt" "spawn_gen=g-$id"
}
tip() { git -C "$PROJ" rev-parse trunk; }
refused() {  # <what> <id> <expect>: landing refuses, mentions <expect>, and leaves the trunk alone
  local before out rc=0
  before=$(tip); out=$(trunk land "$2" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "$1 must refuse, but it landed: $out"
  assert_contains "$out" "$3" "$1 must say why"
  [ "$(tip)" = "$before" ] || fail "$1 moved the trunk"
}

test_a_good_lane_lands_and_goes_live() {
  local out c
  world land
  lane t1 good; c=$(git -C "$PROJ" rev-parse fm/t1)
  out=$(trunk land t1 2>&1) || fail "a proved one-commit lane must land: $out"
  [ "$(tip)" = "$c" ] || fail "the trunk must be at the lane commit"
  [ "$(cat "$HOME_D/state/trunk-tip-proj")" = "$c" ] || fail "the lander must record the new tip"
  assert_contains "$(cat "$HOME_D/data/trunk-landings.tsv")" "$(printf 't1\tproj\t%s' "$c")" "the landing must be logged"
  [ "$(cat "$W/live-moves")" = "$c" ] || fail "the live hook must run at the landed commit"
  assert_contains "$(cat "$HOME_D/data/trunk-live.tsv")" "$(printf '%s\t%s' proj "$c")" "the live move must be logged"
  assert_contains "$out" "live: proj at" "land must report the live move"
  pass 'a one-commit lane lands, is logged, and is live at once'
}

test_every_unsafe_landing_refuses() {
  local old
  world refuse
  lane two a; commit_in "$W/lanes/two" work.txt b "ticket two again"
  refused 'a lane with two commits' two 'one commit per ticket'
  lane bad BAD;  refused 'a failing gate' bad "gate 'full' failed"
  assert_contains "$(ls "$HOME_D/data/trunk")" gate-proj "a failed gate must keep its log"
  lane t1 ok; lane t2 ok2
  trunk land t1 >/dev/null 2>&1 || fail "t1 must land"
  refused 'a lane based on a moved tip' t2 'trunk moved'
  git -C "$W/lanes/t2" reset -q --hard trunk; commit_in "$W/lanes/t2" work.txt ok2 "ticket t2"
  touch "$HOME_D/state/linked-open"; refused 'a ticket linked to an open decision' t2 'linked to a decision'
  rm "$HOME_D/state/linked-open"
  : > "$HOME_D/state/.afk"; refused 'a landing in away mode' t2 'away mode'; rm "$HOME_D/state/.afk"
  lane prot x bin/jg-merge-x.sh; refused 'a protected path' prot 'protected path'
  printf 'abc\n' > "$HOME_D/state/trunk-red-proj"; refused 'a red trunk' t2 'is red'; rm "$HOME_D/state/trunk-red-proj"
  old=$(tip); git -C "$PROJ" branch -f trunk "$(git -C "$PROJ" rev-parse trunk~1)"
  refused 'a trunk a lane moved' t2 'something else moved it'
  git -C "$PROJ" branch -f trunk "$old"
  pass 'every unsafe landing refuses and leaves the trunk where it was'
}

test_a_seam_is_the_only_place_behaviour_changes() {
  local out
  world seam
  lane p x bin/jg-merge-x.sh; refused 'a protected path by default' p 'protected path'
  printf 'protected-landing=gate\n' >> "$HOME_D/config/trunk-policy"
  out=$(trunk land p 2>&1) || fail "protected-landing=gate must let it land after the full gate: $out"
  lane q q; : > "$HOME_D/state/.afk"
  refused 'away mode by default' q 'away mode'
  printf 'away-landing=allowed\n' >> "$HOME_D/config/trunk-policy"
  out=$(trunk land q 2>&1) || fail "away-landing=allowed must let it land: $out"
  rm "$HOME_D/state/.afk"; lane o o
  printf 'trunk-owner=other-home\n' >> "$HOME_D/config/trunk-policy"
  refused 'an owner that is not built' o 'open captain call'
  pass 'a seam value changes behaviour with no code change'
}

test_a_smoke_landing_is_pinned_behind_until_verify_passes() {
  local first c out
  world smoke
  printf 'gate-mode=smoke\ngate-smoke=true\n' >> "$HOME_D/config/trunk-policy"
  first=$(tip); lane s1 BAD; c=$(git -C "$PROJ" rev-parse fm/s1)
  out=$(trunk land s1 2>&1) || fail "a smoke landing must pass the smoke gate: $out"
  assert_contains "$(cat "$HOME_D/data/trunk-live.tsv")" "pinned-behind" "the live record must say the home is pinned behind"
  [ "$(tail -1 "$W/live-moves")" = "$first" ] || fail "the home must stay on the last fully green commit"
  out=$(trunk verify "$PROJ" 2>&1) && fail "verify must fail on a commit the full suite rejects"
  [ -e "$HOME_D/state/trunk-red-proj" ] || fail "a red verify must set the red flag"
  lane s2 fine; refused 'a landing while red' s2 "fixes-red: $c"
  git -C "$W/lanes/s2" reset -q --hard trunk; commit_in "$W/lanes/s2" work.txt fine "ticket s2: fix" "fixes-red: $c"
  trunk land s2 >/dev/null 2>&1 || fail "the fix for the red trunk must land"
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "verify must pass once the fix is in"
  [ ! -e "$HOME_D/state/trunk-red-proj" ] || fail "a green verify must clear the red flag"
  pass 'a smoke landing is pinned behind, a red verify stops landings, and only the fix lands'
}

test_the_batch_release_pushes_without_force_and_opens_one_pr() {
  local out
  world rel
  out=$(trunk release "$PROJ" 2>&1) && fail "an empty batch must refuse"
  assert_contains "$out" 'nothing to release' 'an empty batch must say so'
  lane r1 one; lane r2 two
  trunk land r1 >/dev/null 2>&1 || fail "r1 must land"
  git -C "$W/lanes/r2" reset -q --hard trunk; commit_in "$W/lanes/r2" work.txt two "ticket r2"
  trunk land r2 >/dev/null 2>&1 || fail "r2 must land"
  out=$(trunk release "$PROJ" 2>&1) || fail "a green trunk with a batch must release: $out"
  assert_contains "$out" 'https://github.com/o/r/pull/9' 'the release must report the PR URL'
  [ "$(git --git-dir="$W/origin.git" rev-parse refs/heads/release/c-5)" = "$(tip)" ] || fail "release/c-5 must hold the trunk tip"
  [ "$(wc -l < "$W/gh-calls")" = 1 ] || fail "exactly one release PR must be opened"
  assert_contains "$(cat "$W/gh-calls")" '--head release/c-5' 'the PR must be raised from the release branch'
  out=$(trunk release "$PROJ" 2>&1) && fail "a second release with nothing new must refuse"
  printf 'x\n' > "$HOME_D/state/trunk-red-proj"; out=$(trunk release "$PROJ" 2>&1) && fail "a red trunk must not release"
  pass 'the batch release pushes without force and opens one PR'
}

test_the_bundled_hook_moves_a_home_that_runs_the_project() {
  local c out rc
  world home
  rm "$HOME_D/config/live-hook.proj"
  git clone -q "$(git -C "$PROJ" remote get-url origin)" "$W/homecode"
  lane h1 hook; c=$(git -C "$PROJ" rev-parse fm/h1)
  out=$(CODE_ROOT="$W/homecode" trunk land h1 2>&1) || fail "a landing must move a home that runs the project: $out"
  [ "$(git -C "$W/homecode" rev-parse HEAD)" = "$c" ] || fail "the home checkout must be fast-forwarded to the landed commit: $out"
  grep -Eq "^proj	$c	[0-9]+	live$" "$HOME_D/data/trunk-live.tsv" || fail "the live record must say live"
  out=$(trunk live "$PROJ" 2>&1) || fail "live again must be a no-op: $out"
  rm "$HOME_D/data/trunk-live.tsv"; printf 'dirty\n' >> "$W/homecode/README.md"
  lane h2 hook2; rc=0; out=$(CODE_ROOT="$W/homecode" trunk land h2 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "a landing whose home did not move must exit 3, got $rc: $out"
  [ "$(tip)" = "$(git -C "$PROJ" rev-parse fm/h2)" ] || fail "the commit must stay landed when only the live step failed"
  assert_contains "$(cat "$HOME_D/data/trunk-live.tsv")" hook-failed "a home that did not move must be recorded as such"
  pass 'the bundled hook fast-forwards the home and a dirty home is recorded as not moved'
}

test_the_current_trunk_is_the_newest_versioned_branch() {
  local out c
  world versioned
  git -C "$PROJ" branch trunk-v2 trunk; git -C "$PROJ" branch trunk-v10 trunk; git -C "$PROJ" branch trunk-v3 trunk
  git -C "$PROJ" branch -D trunk >/dev/null
  git -C "$PROJ" worktree add -q -b fm/v1 "$W/lanes/v1" trunk-v10
  commit_in "$W/lanes/v1" work.txt good "ticket v1"
  jg_write_meta "$HOME_D/state/v1.meta" "project=$PROJ" "mode=trunk" "branch=fm/v1" "worktree=$W/lanes/v1" "spawn_gen=g-v1"
  c=$(git -C "$PROJ" rev-parse fm/v1)
  out=$(trunk land v1 2>&1) || fail "a lane must land on the newest trunk-vN: $out"
  [ "$(git -C "$PROJ" rev-parse trunk-v10)" = "$c" ] || fail "the newest trunk-vN must move, not a fixed trunk"
  git -C "$PROJ" rev-parse --verify -q refs/heads/trunk >/dev/null && fail "land must not recreate the fixed name trunk"
  [ "$(cat "$W/live-moves")" = "$c" ] || fail "go live must run at the versioned trunk commit"
  pass 'every subcommand resolves the newest trunk-vN, not the fixed name trunk'
}

test_a_project_with_no_trunk_keeps_its_plain_refusal() {
  local out rc=0
  world notrunk
  rm -f "$HOME_D/state/trunk-tip-proj"; git -C "$PROJ" branch -D trunk >/dev/null
  out=$(trunk live "$PROJ" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "live without a trunk must refuse"
  assert_contains "$out" "REFUSED: no trunk for proj; run: jg-trunk.sh init $PROJ" "the no-trunk refusal wording must not change"
  pass 'a project with no trunk keeps its exact refusal'
}

test_a_good_lane_lands_and_goes_live
test_the_current_trunk_is_the_newest_versioned_branch
test_a_project_with_no_trunk_keeps_its_plain_refusal
test_the_bundled_hook_moves_a_home_that_runs_the_project
test_every_unsafe_landing_refuses
test_a_seam_is_the_only_place_behaviour_changes
test_a_smoke_landing_is_pinned_behind_until_verify_passes
test_the_batch_release_pushes_without_force_and_opens_one_pr
printf 'jg-trunk: ok\n'
