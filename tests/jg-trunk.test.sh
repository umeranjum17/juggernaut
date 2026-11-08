#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh: the local trunk flow end to end against real git
# repositories, a local bare origin, the real gate chain and a stub for the captain-hold reader.
#
# T1 A one-commit lane lands on the trunk by compare-and-swap and is logged, but landing never goes live: live
#    refuses without the captain's recorded word, runs the hook at the green commit with it, and spends the word.
#    The green pin moves only when verify (the whole suite, after the landing) passes.
# T2 Every unsafe landing refuses and leaves the trunk where it was: a second commit, a conflicting change (it names its
#    paths), a failing gate, a failing lint, an owner-guard hit, a red trunk, away mode, a ref a lane moved, a
#    decision still open on linked work, a protected path, and a commit with no ticket reference.
# T3 The seams are the only place behaviour changes: protected-landing=gate and away-landing=allowed
#    let the same commits land, with no code change; the gate commands are policy keys with fast defaults.
# T5 The release is ONE PR from the trunk itself into the default branch: no release branch, no
#    force, refused without the captain's word, and a second release while it is open opens no
#    second PR; an empty batch, a red trunk and an unverified tip refuse.
# T8 Only the lander moves the trunk: a hand write to it is refused by the hook the trunk installs;
#    land records the same merged event as the local merge.
# T9 The trunk is safe until its release PR lands: no write rewinds, forces or deletes it, even the lander's
#    own; once the release merged, the next trunk version (trunk-v2) is cut from the default branch, recorded,
#    and landed on, with the old trunk untouched; while it is open, nothing rolls over.
# T10 Once the next trunk is cut, the old one is cleaned up unforced - remote branch, local branch, worktrees - only
#    when its release is proved on main and every hotfix is carried into the new trunk; a copy holding
#    unlanded work, or a hotfix not carried, keeps it, listed.
# T7 The registered check core/trunk-landing lands a task whose last status line is its done, with no human step, and
#    never goes live; it ignores a task that is not done, reports a refusal once (a conflict names its paths), retries a
#    refusal that only needs time, cleans a landed task up unforced, and runs on the watcher's fast tick.
# T11 The landing gate charges a lane only for what it broke: a script red on the trunk tip in the same way does not block
#    (it is reported once per tip tree, and the green pin stays), while a script that fails only on the lane, passes on the
#    tip, or fails differently on the lane blocks it, with the tip's rerun done in the environment the gate ended with.
#    A failure gets one rerun on the lane before it is judged: one that passes on the rerun is flaky and not charged.
# T12 A landing is one fast check: the lander rebases the lane's one commit onto the tip by itself (the lane follows it),
#    and the done-done seal, the merge-card and the owner signature never block it, whatever they are; what exists is recorded.
# T13 The journey: four lanes ready at once, three land in order with no human or lead step, the red one is refused,
#    and a commit that passes the landing check but breaks the whole suite is reverted by itself after the landing and
#    the lane is told; a revert that cannot apply cleanly writes the red pin instead.
# T6 A red CI pins the home back to the last green live commit and stops landings; a worker
#    cannot record the captain's word.
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
if [ "\$2" = view ]; then
  [ "\$3" = 9 ] && [ "\$4" = --repo ] && [ "\$5" = o/r ] || { echo 'error: gh-axi requires a PR number and --repo' >&2; exit 1; }
  printf 'state: %s\n' "\$(cat "$W/pr-state" 2>/dev/null || echo open)"; exit 0; fi
printf 'https://github.com/o/r/pull/9\n'
SH
  cat > "$HOME_D/config/live-hook.proj" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$2" >> "$W/live-moves"
SH
  cat > "$W/root/bin/jg-fleet-ledger.sh" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$W/ledger-calls"
SH
  cat > "$W/root/bin/jg-teardown.sh" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$W/teardown-calls"
SH
  : > "$HOME_D/config/fleet-ledger"
  chmod +x "$W/root/bin/jg-fleet-ledger.sh" "$W/root/bin/jg-teardown.sh" "$W/root/bin/jg-captain-hold.sh" "$W/fakebin/gh-axi" "$HOME_D/config/live-hook.proj"
  printf 'gate-full=! grep -q BAD work.txt\ngate-verify=! grep -q BAD work.txt\ngate-lint=! grep -q UGLY work.txt\n' > "$HOME_D/config/trunk-policy"
  printf -- '- proj [local-trunk] - fixture project in local-trunk mode (added 2026-11-07)\n' > "$HOME_D/data/projects.md"
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
# prove <id> [PASS|FAIL]: the sealed done-done receipt for the lane's current head.
prove() {
  printf '{"schema":1,"task":"%s","mode":"local-trunk","spawn_gen":"g-%s","head":"%s","pr":"","verdict":"%s","at":1,"evidence":"done-done run: ok"}\n' \
    "$1" "$1" "$(git -C "$PROJ" rev-parse "fm/$1")" "${2:-PASS}" > "$HOME_D/state/$1.run-receipt.json"
}
# lane <id> <content> [<file>] [<note>]: a lane off the trunk tip with one commit and a PASS receipt.
lane() {
  local id=$1 wt="$W/lanes/$1"
  git -C "$PROJ" worktree add -q -b "fm/$id" "$wt" trunk
  commit_in "$wt" "${3:-work.txt}" "$2" "ticket $id" "${4-}"
  jg_write_meta "$HOME_D/state/$id.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/$id" "worktree=$wt" "spawn_gen=g-$id"
  prove "$id"; ready "$id"
}
# ready <id>: the worker's own report that the lane is done, the only signal the landing check waits for.
READY_AT=1000
ready() { READY_AT=$((READY_AT + 1)); printf 'done [at=%s]: ready in branch fm/%s (local-trunk)\n' "$READY_AT" "$1" >> "$HOME_D/state/$1.status"; }
# relane <id> <content>: the lane is rebased onto the trunk tip with one new commit and proved again.
relane() { git -C "$W/lanes/$1" reset -q --hard trunk; commit_in "$W/lanes/$1" work.txt "$2" "ticket $1"; prove "$1"; }
# plain_git: git with no machine-wide hooks path, so the project's own reference-transaction hook is the one that runs.
plain_git() { env GIT_CONFIG_COUNT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
tip() { git -C "$PROJ" rev-parse trunk; }
refused() {  # <what> <id> <expect>: landing refuses, mentions <expect>, and leaves the trunk alone
  local before out rc=0
  before=$(tip); out=$(trunk land "$2" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "$1 must refuse, but it landed: $out"
  assert_contains "$out" "$3" "$1 must say why"
  [ "$(tip)" = "$before" ] || fail "$1 moved the trunk"
}

test_legacy_mode_stays_interoperable() {
  world legacy
  lane old one
  sed -i 's/^mode=local-trunk$/mode=local-only/' "$HOME_D/state/old.meta"
  sed -i 's/"mode":"local-trunk"/"mode":"local-only"/' "$HOME_D/state/old.run-receipt.json"
  trunk land old >/dev/null 2>&1 || fail "legacy local-only records must still land"
  grep -qx mode=local-only "$HOME_D/state/old.meta" || fail "legacy records must not be rewritten"
  pass 'a legacy local-only record lands without a mode rewrite'
}

test_a_good_lane_lands_but_goes_live_only_on_his_word() {
  local out c green
  world land
  green=$(tip); lane t1 good; c=$(git -C "$PROJ" rev-parse fm/t1)
  out=$(trunk land t1 2>&1) || fail "a proved one-commit lane must land: $out"
  [ "$(tip)" = "$c" ] || fail "the trunk must be at the lane commit"
  [ "$(cat "$HOME_D/state/trunk-tip-proj")" = "$c" ] || fail "the lander must record the new tip"
  assert_contains "$(cat "$HOME_D/data/trunk-landings.tsv")" "$(printf 't1\tproj\t%s' "$c")" "the landing must be logged"
  assert_contains "$(cat "$W/ledger-calls")" "merged t1 local" "land must raise the same merged event as the local merge"
  [ ! -e "$W/live-moves" ] || fail "landing must never run the live hook"
  [ ! -e "$HOME_D/data/trunk-live.tsv" ] || fail "landing must not record a live move"
  assert_contains "$out" "not live" "land must say the trunk is not live"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$green" ] || fail "a landing must not move the green pin: only verify, the whole suite, does"
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "verify must pass on the landed commit"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$c" ] || fail "a green verify must move the green pin to the landed commit"
  out=$(trunk live "$PROJ" 2>&1) && fail "live must refuse without the captain's word"
  assert_contains "$out" "no recorded word from the captain" "live must say it needs his word"
  out=$(JG_TASK_ID=t1 trunk word live "$PROJ" "go" 2>&1) && fail "a worker must not record the captain's word"
  assert_contains "$out" "worker never records" "a worker's word must be refused by name"
  trunk word live "$PROJ" "" >/dev/null 2>&1 && fail "a word with no quote must refuse"
  trunk word live "$PROJ" "go live" >/dev/null 2>&1 || fail "the captain's word must record"
  out=$(trunk live "$PROJ" 2>&1) || fail "live with his word must move the home: $out"
  [ "$(cat "$W/live-moves")" = "$c" ] || fail "the live hook must run at the green commit"
  assert_contains "$(cat "$HOME_D/data/trunk-live.tsv")" "$(printf '%s\t%s' proj "$c")" "the live move must be logged"
  trunk live "$PROJ" >/dev/null 2>&1 && fail "his word is spent by one live"
  [ "$green" != "$c" ] || fail "fixture: the lane must differ from the trunk base"
  pass 'a one-commit lane lands, is logged, and goes live only on the captain'"'"'s recorded word'
}

test_every_unsafe_landing_refuses() {
  local old
  world refuse
  lane two a; commit_in "$W/lanes/two" work.txt b "ticket two again"
  refused 'a lane with two commits' two 'one commit per ticket'
  lane noref a2; git -C "$W/lanes/noref" -c user.name=t -c user.email=t@example.invalid commit -q --amend -m "a change with no reference"; prove noref
  refused 'a commit with no ticket reference' noref 'ticket reference'
  lane ugly UGLY; refused 'a failing lint' ugly "gate 'lint' failed"
  printf 'SECRETWORD\n' > "$HOME_D/config/owner-details-patterns"; lane leak SECRETWORD; refused 'an owner-guard hit' leak 'owner-guard'; rm "$HOME_D/config/owner-details-patterns"
  lane bad BAD;  refused 'a failing gate' bad "gate 'full' failed"
  [ -n "$(find "$HOME_D/data/jg-trunk-landing" -name gate-full.log -print)" ] || fail "a failed gate must keep its attempt log"
  lane t1 ok; lane t2 ok2 t2.txt
  trunk land t1 >/dev/null 2>&1 || fail "t1 must land"
  git -C "$PROJ" merge-base --is-ancestor trunk "fm/t2" && fail "fixture: t2 must still be based on the old tip"
  lane clash CLASH; git -C "$W/lanes/clash" reset -q --hard "$(git -C "$PROJ" rev-parse trunk~1)"; commit_in "$W/lanes/clash" work.txt other "ticket clash"; prove clash
  refused 'a conflicting lane' clash 'conflicts with trunk'
  assert_contains "$(trunk land clash 2>&1)" 'in: work.txt' 'a conflict must name its paths'
  for flag in --force -f --no-verify --skip-gates; do
    b4=$(tip); out=$(trunk land "$flag" t2 2>&1) && fail "a landing with $flag must be refused: $out"
    assert_contains "$out" "never forced" "a landing with $flag must say it is never forced"
    [ "$(tip)" = "$b4" ] || fail "a forced landing with $flag moved the trunk"
  done
  out=$(trunk land t2 extra 2>&1) && fail "land with a stray argument must be refused: $out"
  assert_contains "$out" "only the task id" "a stray argument must be refused by name"
  relane t2 ok2
  touch "$HOME_D/state/linked-open"; refused 'a ticket linked to an open decision' t2 'linked to a decision'
  rm "$HOME_D/state/linked-open"
  : > "$HOME_D/state/.afk"; refused 'a landing in away mode' t2 'away mode'; rm "$HOME_D/state/.afk"
  lane prot x bin/jg-merge-x.sh; refused 'a protected path' prot 'protected path'
  printf 'abc\n' > "$HOME_D/state/trunk-red-proj"; refused 'a red trunk' t2 'is red'; rm "$HOME_D/state/trunk-red-proj"
  old=$(tip)
  plain_git -C "$PROJ" branch -f trunk "$(git -C "$PROJ" rev-parse trunk~1)" 2>/dev/null && fail "a hand write to the trunk must be refused by the hook"
  JG_TRUNK_WRITER=1 plain_git -C "$PROJ" branch -f trunk "$(git -C "$PROJ" rev-parse trunk~1)" 2>/dev/null && fail "even the lander's own writer must not rewind the trunk"
  JG_TRUNK_WRITER=1 plain_git -C "$PROJ" branch -D trunk 2>/dev/null && fail "a trunk must never be deleted"
  [ "$(tip)" = "$old" ] || fail "a refused write must leave the trunk where it was"
  printf '%s\n' "$(git -C "$PROJ" rev-parse trunk~1)" > "$HOME_D/state/trunk-tip-proj"
  refused 'a trunk whose record does not match' t2 'something else moved it'
  printf '%s\n' "$old" > "$HOME_D/state/trunk-tip-proj"
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

test_a_landing_is_pinned_behind_until_verify_passes() {
  local first c out
  world smoke
  first=$(tip); lane s1 BAD; c=$(git -C "$PROJ" rev-parse fm/s1)
  printf 'gate-full=true\n' >> "$HOME_D/config/trunk-policy"
  out=$(trunk land s1 2>&1) || fail "a landing must pass the fast check: $out"
  trunk word live "$PROJ" "go live" >/dev/null || fail "the captain's word must record"
  out=$(trunk live "$PROJ" 2>&1) || fail "live must work with his word: $out"
  assert_contains "$(cat "$HOME_D/data/trunk-live.tsv")" "pinned-behind" "the live record must say the home is pinned behind"
  [ "$(tail -1 "$W/live-moves")" = "$first" ] || fail "the home must stay on the last fully green commit"
  out=$(trunk verify "$PROJ" "$c" 2>&1) && fail "verify must fail on a commit the whole suite rejects"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$first" ] || fail "a red verify must not move the green pin"
  pass 'a landing is pinned behind until verify passes'
}

test_the_release_is_one_pr_from_the_trunk_on_his_word() {
  local out
  world rel
  out=$(trunk release "$PROJ" 2>&1) && fail "an empty batch must refuse"
  assert_contains "$out" 'nothing to release' 'an empty batch must say so'
  lane r1 one; lane r2 two
  trunk land r1 >/dev/null 2>&1 || fail "r1 must land"
  relane r2 two
  trunk land r2 >/dev/null 2>&1 || fail "r2 must land"
  out=$(trunk release "$PROJ" 2>&1) && fail "a release must refuse until the trunk is fully green"
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "verify must pass"
  out=$(trunk release "$PROJ" 2>&1) && fail "a release must refuse without the captain's word"
  assert_contains "$out" 'no recorded word from the captain to release' 'a release without his word must say so'
  [ ! -e "$W/gh-calls" ] || fail "a refused release must open nothing"
  trunk word release "$PROJ" "ship it" >/dev/null 2>&1 || fail "the captain's word must record"
  out=$(trunk release "$PROJ" 2>&1) || fail "a green trunk with a batch and his word must release: $out"
  assert_contains "$out" 'https://github.com/o/r/pull/9' 'the release must report the PR URL'
  [ "$(git --git-dir="$W/origin.git" rev-parse refs/heads/trunk)" = "$(tip)" ] || fail "origin trunk must hold the trunk tip"
  git --git-dir="$W/origin.git" for-each-ref --format='%(refname)' 'refs/heads/release/c-5*' | grep -q . && fail "no release branch may be created"
  [ "$(grep -c 'pr create' "$W/gh-calls")" = 1 ] || fail "exactly one release PR must be opened"
  assert_contains "$(cat "$W/gh-calls")" '--head trunk' 'the PR must be raised from the trunk itself'
  out=$(trunk release "$PROJ" 2>&1) && fail "a second release with nothing new must refuse"
  lane r3 three; trunk land r3 >/dev/null 2>&1 || fail "r3 must land"
  trunk verify "$PROJ" >/dev/null 2>&1; trunk word release "$PROJ" "ship it again" >/dev/null 2>&1
  out=$(trunk release "$PROJ" 2>&1) || fail "a later batch must release: $out"
  [ "$(grep -c 'pr create' "$W/gh-calls")" = 1 ] || fail "a release while the PR is open must open no second PR"
  [ "$(git --git-dir="$W/origin.git" rev-parse refs/heads/trunk)" = "$(tip)" ] || fail "the open PR must carry the new commits"
  printf 'x\n' > "$HOME_D/state/trunk-red-proj"; out=$(trunk release "$PROJ" 2>&1) && fail "a red trunk must not release"
  pass 'the release is one PR from the trunk itself, on his word, with no release branch'
}

test_the_trunk_stays_safe_until_its_release_lands_then_the_next_version_is_cut() {
  local out old
  world roll
  lane v1 one; trunk land v1 >/dev/null 2>&1 || fail "v1 must land"
  trunk verify "$PROJ" >/dev/null 2>&1; trunk word release "$PROJ" "ship it" >/dev/null 2>&1
  trunk release "$PROJ" >/dev/null 2>&1 || fail "the release must open"
  old=$(tip)
  out=$(trunk rollover "$PROJ" 2>&1) && fail "an open release must not roll the trunk over"
  assert_contains "$out" "no merged release" "an open release must say why nothing moved"
  plain_git -C "$PROJ" show-ref --verify --quiet refs/heads/trunk-v2 && fail "no next trunk may exist while the release is open"
  printf 'merged\n' > "$W/pr-state"; git -C "$PROJ" push -q origin "$old:refs/heads/main"
  out=$(trunk rollover "$PROJ" 2>&1) || fail "a merged release must cut the next trunk: $out"
  [ "$(git -C "$PROJ" rev-parse trunk-v2)" = "$old" ] || fail "trunk-v2 must be cut from the merged default branch"
  assert_contains "$out" "deleted local trunk" "the proved and carried old trunk must be cleaned up"
  assert_contains "$out" "deleted remote trunk" "the old trunk's remote branch must be deleted"
  git -C "$PROJ" rev-parse --verify -q refs/heads/trunk >/dev/null && fail "the old local trunk must be gone"
  [ "$(cat "$HOME_D/state/trunk-branch-proj")" = trunk-v2 ] && [ "$(cat "$HOME_D/state/trunk-version-proj")" = 2 ] || fail "the trunk record must name version 2"
  assert_contains "$(cat "$HOME_D/data/trunk-versions.tsv")" "$(printf 'proj\t2\ttrunk-v2\t%s' "$old")" "the version must be recorded"
  out=$(trunk rollover "$PROJ" 2>&1) && fail "one release rolls over once"
  git -C "$PROJ" worktree add -q -b fm/n1 "$W/lanes/n1" trunk-v2; commit_in "$W/lanes/n1" work.txt next "ticket n1"
  jg_write_meta "$HOME_D/state/n1.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/n1" "worktree=$W/lanes/n1" "spawn_gen=g-n1"; prove n1
  out=$(trunk land n1 2>&1) || fail "a lane must land on the next trunk: $out"
  [ "$(git -C "$PROJ" rev-parse trunk-v2)" = "$(git -C "$PROJ" rev-parse fm/n1)" ] || fail "the next trunk must hold the landed commit"
  pass 'the trunk is safe until its release lands, then the next version is cut and the project moves onto it'
}

test_the_old_trunk_is_cleaned_up_unforced_and_only_when_its_work_is_carried() {
  local out old hot wt
  world retire
  lane o1 one; trunk land o1 >/dev/null 2>&1 || fail "o1 must land"
  trunk verify "$PROJ" >/dev/null 2>&1; trunk word release "$PROJ" "ship it" >/dev/null 2>&1; trunk release "$PROJ" >/dev/null 2>&1 || fail "release must open"
  old=$(tip); wt="$W/oldwt"
  lane hx hotfix hot.txt; hot=$(git -C "$PROJ" rev-parse fm/hx); trunk land hx >/dev/null 2>&1 || fail "the hotfix must land on the old trunk while its release is open"
  git -C "$PROJ" worktree add -q "$wt" trunk; printf 'scratch\n' > "$wt/unsaved.txt"
  printf 'merged\n' > "$W/pr-state"; git -C "$PROJ" push -q origin "$old:refs/heads/main"
  out=$(trunk rollover "$PROJ" 2>&1) || fail "the merged release must roll over: $out"
  assert_contains "$out" "kept trunk: hotfix not carried into trunk-v2: " "a hotfix not carried must keep the old trunk and be listed"
  assert_contains "$out" "ticket hx" "the uncarried hotfix must be named"
  git -C "$PROJ" rev-parse --verify -q refs/heads/trunk >/dev/null || fail "an old trunk with an uncarried hotfix must not be deleted"
  git --git-dir="$W/origin.git" rev-parse --verify -q refs/heads/trunk >/dev/null || fail "its remote branch must not be deleted either"
  [ -d "$wt" ] || fail "a worktree on it must not be removed"
  git -C "$PROJ" worktree add -q -b fm/hx2 "$W/lanes/hx2" trunk-v2; git -C "$W/lanes/hx2" cherry-pick -n "$hot" >/dev/null 2>&1 || fail "the hotfix must cherry-pick"
  git -C "$W/lanes/hx2" -c user.name=t -c user.email=t@example.invalid commit -q -m "ticket hx2: carry hotfix hx"
  jg_write_meta "$HOME_D/state/hx2.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/hx2" "worktree=$W/lanes/hx2" "spawn_gen=g-hx2"; prove hx2
  trunk land hx2 >/dev/null 2>&1 || fail "the carried hotfix must land on trunk-v2"
  out=$(trunk retire "$PROJ" 2>&1) || fail "retire must not fail: $out"
  assert_contains "$out" "kept worktree $wt: it holds uncommitted work" "a worktree with unlanded work must be kept and listed"
  assert_contains "$out" "kept local trunk" "its branch must be kept with it"
  [ -f "$wt/unsaved.txt" ] || fail "unlanded work must never be deleted"
  git --git-dir="$W/origin.git" rev-parse --verify -q refs/heads/trunk >/dev/null && fail "the carried remote branch must be deleted"
  rm -f "$wt/unsaved.txt"
  out=$(trunk retire "$PROJ" 2>&1) || fail "retire must not fail: $out"
  assert_contains "$out" "removed worktree" "a clean worktree on the old trunk must be removed"
  assert_contains "$out" "deleted local trunk" "the old local trunk must be deleted once nothing holds unlanded work"
  [ ! -d "$wt" ] || fail "the old trunk's worktree must be gone"
  ! git -C "$PROJ" rev-parse --verify -q refs/heads/trunk >/dev/null || fail "the old local trunk must be gone"
  [ -z "$(trunk retire "$PROJ" 2>&1)" ] || fail "retire with nothing left must be silent"
  pass 'the old trunk is cleaned up unforced, only once its release is proved on main and every hotfix is carried'
}

test_a_red_ci_pins_the_home_back_to_the_last_green_commit() {
  local c1 c2 out
  world ci
  lane c1 one; c1=$(git -C "$PROJ" rev-parse fm/c1); trunk land c1 >/dev/null 2>&1 || fail "c1 must land"
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "c1 must verify"
  trunk word live "$PROJ" "go" >/dev/null 2>&1; trunk live "$PROJ" >/dev/null 2>&1 || fail "c1 must go live"
  lane c2 two; c2=$(git -C "$PROJ" rev-parse fm/c2); trunk land c2 >/dev/null 2>&1 || fail "c2 must land"
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "c2 must verify"
  trunk word live "$PROJ" "go" >/dev/null 2>&1; trunk live "$PROJ" >/dev/null 2>&1 || fail "c2 must go live"
  [ "$(tail -1 "$W/live-moves")" = "$c2" ] || fail "fixture: the home must be at c2"
  out=$(trunk ci "$PROJ" "$c2" red 2>&1) || fail "a red CI must record and pin back: $out"
  [ "$(tail -1 "$W/live-moves")" = "$c1" ] || fail "a red CI must move the home back to the last green live commit"
  [ "$(cat "$HOME_D/state/trunk-red-proj")" = "$c2" ] || fail "a red CI must write the red pin"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$c1" ] || fail "the green pin must be the last green commit"
  lane c3 three; refused 'a landing while CI is red' c3 "fixes-red: $c2"
  trunk word live "$PROJ" "go" >/dev/null 2>&1; trunk live "$PROJ" >/dev/null 2>&1 || fail "live after a pin-back must work with his word"
  [ "$(tail -1 "$W/live-moves")" = "$c1" ] || fail "the home must stay pinned on the last green commit"
  pass 'a red CI writes the pin-back, returns the home to the last green commit and stops landings'
}

sweep() {  # one check sweep over the fixture home, then wait for the detached landings it started
  local out
  out=$(JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D") || fail "the check must not fail: $out"
  for _ in $(seq 1 100); do grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state || break; sleep 0.2; done
  printf '%s' "$out"
}

test_the_registered_check_lands_a_proved_task_without_a_human() {
  local out c
  world auto
  # the check runs the home's own bin, so the fixture home needs the copied bin and a mode the check reads
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  lane a1 one; lane a2 two; rm "$HOME_D/state/a2.status"
  sweep >/dev/null; out=$(sweep)
  [ "$(tip)" = "$(git -C "$PROJ" rev-parse fm/a1)" ] || fail "the check must land the proved task by itself: $out"
  assert_contains "$out" "landed a1" "the landing must be reported"
  assert_contains "$out" "cleaned up" "a landed task must be cleaned up"
  [ "$(cat "$W/teardown-calls")" = a1 ] || fail "cleanup must run unforced: jg-teardown.sh <id> and nothing else"
  [ -z "$(sweep)" ] || fail "a reported landing must not repeat"
  [ ! -e "$W/live-moves" ] || fail "the check must never go live"
  git -C "$PROJ" merge-base --is-ancestor "$(git -C "$PROJ" rev-parse fm/a2)" trunk && fail "a task that is not done must not land"
  git -C "$W/lanes/a2" reset -q --hard "$(git -C "$PROJ" rev-parse trunk~1)"; commit_in "$W/lanes/a2" work.txt clash "ticket a2"; ready a2
  sweep >/dev/null; out=$(sweep)
  assert_contains "$out" "a2 not landed" "a refusal must be reported"
  assert_contains "$out" "in: work.txt" "a conflict must name its paths"
  [ -z "$(sweep)" ] || fail "a final refusal must be reported once"
  lane a3 three; : > "$HOME_D/state/.afk"
  sweep >/dev/null; assert_contains "$(sweep)" "a3 waits to land" "a time-only refusal must be reported"
  [ -z "$(sweep)" ] || fail "a waiting refusal must not repeat"
  rm "$HOME_D/state/.afk"; sweep >/dev/null; sweep >/dev/null
  c=$(git -C "$PROJ" rev-parse fm/a3); [ "$(tip)" = "$c" ] || fail "a waiting task must land once the wait clears"
  pass 'the registered check lands a proved task by itself, reports refusals once, and never goes live'
}

test_the_watcher_runs_the_landing_check_on_its_fast_tick() {
  local c out rc=0 st
  world outer-watch
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  printf 'off\n' > "$HOME_D/config/wake-bus"
  lane ready one; c=$(git -C "$PROJ" rev-parse fm/ready)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/tmux"; chmod +x "$W/fakebin/tmux"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$W/fakebin/systemctl"; chmod +x "$W/fakebin/systemctl"
  printf '#!/usr/bin/env bash\nsleep 0.2\nexec %s "$@"\n' "$(command -v setsid)" > "$W/fakebin/setsid"; chmod +x "$W/fakebin/setsid"
  JG_HOME="$HOME_D" JG_STATE_OVERRIDE="$HOME_D/state" bash -c \
    '. "$1"; jg_wake_append check urgent "check: waiting-state urgent blocker"' _ "$ROOT/bin/jg-wake-lib.sh" \
    || fail "could not queue the urgent wake"
  JG_HOME="$HOME_D" "$ROOT/bin/jg-bus.sh" watcher oldest >/dev/null || fail "could not observe the queued wake"
  sleep 2
  out=$(env -u JG_TASK_ID PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" JG_ROOT_OVERRIDE="$W/root" \
    JG_STATE_OVERRIDE="$HOME_D/state" JG_CONFIG_OVERRIDE="$HOME_D/config" JG_POLL=1 JG_SIGNAL_GRACE=0 \
    JG_WATCH_HANDLING_SUCCESSOR=1 JG_SQUAD_LEAD_WAKE_STALL_SECS=1 JG_FAST_CHECK_INTERVAL=0 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 \
    timeout 60 "$HOME_D/bin/jg-watch.sh" 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "outer watcher failed ($rc): $out"
  assert_contains "$out" 'check: waiting-state urgent blocker' 'the urgent wake must still be delivered'
  st="$HOME_D/data/jg-trunk-landing/ready.$c.state"
  [ -e "$st" ] || fail "urgent queue exit skipped the eligible ready/PASS landing check: $out"
  printf 'outer-check: ready/PASS dispatch exists before urgent wake exit; fixture=%s\n' "$W"
  for _ in $(seq 1 600); do grep -Eq '^landed( |$)' "$st" && break; sleep 0.1; done
  grep -Eq '^landed( |$)' "$st" || fail "detached landing did not finish: $(cat "$st" "$HOME_D/data/jg-trunk-landing/ready.$c.log")"
  [ "$(tip)" = "$c" ] || fail "outer watcher dispatched but did not land the exact ready head"
  [ ! -e "$W/live-moves" ] || fail "outer watcher must never release or go live"
  pass 'real outer watcher dispatches and lands ready/PASS before an urgent queued wake exits; never goes live'
}

test_the_landing_check_cuts_the_next_trunk_once_the_release_merged() {
  local out
  world rolcheck
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  lane k1 one; trunk land k1 >/dev/null 2>&1 || fail "k1 must land"
  trunk verify "$PROJ" >/dev/null 2>&1; trunk word release "$PROJ" "ship it" >/dev/null 2>&1; trunk release "$PROJ" >/dev/null 2>&1 || fail "release must open"
  out=$(sweep); [ -z "$out" ] || fail "an open release must change nothing: $out"
  printf 'merged\n' > "$W/pr-state"; git -C "$PROJ" push -q origin "$(tip):refs/heads/main"; rm -f "$HOME_D"/data/jg-trunk-landing/.rollover-*
  out=$(sweep); assert_contains "$out" "release merged: the project is now on trunk-v2" "the check must cut the next trunk"
  git -C "$PROJ" rev-parse --verify -q trunk-v2 >/dev/null || fail "trunk-v2 must exist"
  pass 'the landing check cuts the next trunk once the release merged'
}

test_the_bundled_hook_moves_a_home_that_runs_the_project() {
  local c out rc base
  world home
  rm "$HOME_D/config/live-hook.proj"
  git clone -q "$(git -C "$PROJ" remote get-url origin)" "$W/homecode"
  lane h1 hook; c=$(git -C "$PROJ" rev-parse fm/h1)
  out=$(CODE_ROOT="$W/homecode" trunk land h1 2>&1) || fail "h1 must land: $out"
  [ "$(git -C "$W/homecode" rev-parse HEAD)" != "$c" ] || fail "landing alone must not move the home checkout"
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "h1 must verify"
  trunk word live "$PROJ" "go" >/dev/null 2>&1
  out=$(CODE_ROOT="$W/homecode" trunk live "$PROJ" 2>&1) || fail "live must move a home that runs the project: $out"
  [ "$(git -C "$W/homecode" rev-parse HEAD)" = "$c" ] || fail "the home checkout must be fast-forwarded to the landed commit: $out"
  grep -Eq "^proj	$c	[0-9]+	live$" "$HOME_D/data/trunk-live.tsv" || fail "the live record must say live"
  base=$(cat "$HOME_D/state/trunk-released-proj")
  out=$(CODE_ROOT="$W/homecode" trunk ci "$PROJ" "$c" red 2>&1) || fail "a red CI must pin the bundled home back: $out"
  [ "$(git -C "$W/homecode" rev-parse HEAD)" = "$base" ] || fail "the home checkout must return to the last release when no earlier commit was live: $out"
  rm -f "$HOME_D/state/trunk-red-proj"; printf '%s\n' "$c" > "$HOME_D/state/trunk-green-proj"
  rm "$HOME_D/data/trunk-live.tsv"; printf 'dirty\n' >> "$W/homecode/README.md"
  lane h2 hook2; CODE_ROOT="$W/homecode" trunk land h2 >/dev/null 2>&1 || fail "h2 must land"
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "h2 must verify"
  trunk word live "$PROJ" "go" >/dev/null 2>&1
  rc=0; out=$(CODE_ROOT="$W/homecode" trunk live "$PROJ" 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "a live whose home did not move must exit 3, got $rc: $out"
  [ "$(tip)" = "$(git -C "$PROJ" rev-parse fm/h2)" ] || fail "the commit must stay landed when only the live step failed"
  assert_contains "$(cat "$HOME_D/data/trunk-live.tsv")" hook-failed "a home that did not move must be recorded as such"
  pass 'the bundled hook fast-forwards the home and a dirty home is recorded as not moved'
}

# A stand-in for bin/jg-test-run.sh that keeps its marker contract: it runs t/*.test.sh (or the paths it is given) in the clone.
rig() {
  cat > "$W/rig.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --all ] || set -- t/*.test.sh
total=0 failed=0
for s in "$@"; do
  echo "JG_TEST_BEGIN 2026-01-01T00:00:00Z $s family=x expected_gate_skip=none"
  bash "$s" 2>&1; rc=$?
  echo "JG_TEST_END 2026-01-01T00:00:00Z $s exit=$rc duration_ms=1 gate_skip=false"
  total=$((total + 1)); [ "$rc" -eq 0 ] || failed=$((failed + 1))
done
echo "JG_TEST_SUMMARY total=$total failed=$failed skipped_gate=0 duration_ms=1"
[ "$failed" -eq 0 ]
SH
  printf 'gate-full=export GATE_MARK=yes; bash %s/rig.sh --all\ngate-rerun=bash %s/rig.sh\ngate-red-ticket=ticket-red\n' "$W" "$W" >> "$HOME_D/config/trunk-policy"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/backlog-calls"\n' "$W" > "$W/root/bin/jg-backlog.sh"; chmod +x "$W/root/bin/jg-backlog.sh"
}
# The tip carries a red that shows only in the gate's environment, and a script that passes.
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
seed_red_tip() {
  git -C "$PROJ" worktree add -q -b seed "$W/seed" trunk
  commit_in "$W/seed" t/a.test.sh '[ "${GATE_MARK:-}" = yes ] && { echo "not ok - tip case" >&2; exit 1; }; exit 0' "seed a"
  commit_in "$W/seed" t/c.test.sh 'exit 0' "seed c"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/seed" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_the_full_gate_charges_a_lane_only_for_what_it_broke() {
  local out tipc green
  world base; rig; seed_red_tip; tipc=$(tip)
  # A lane that adds a failing script of its own: blocked by name, and the tip's red is reported.
  lane intro 'echo "not ok - lane case" >&2; exit 1' t/b.test.sh
  refused 'a failure only the lane has' intro 't/b.test.sh'
  assert_contains "$(trunk land intro 2>&1 || true)" "introduced or changed" "the refusal must say the lane caused it"
  # A lane that makes the tip's red worse (an added failing case in the same script): blocked.
  lane worse '[ "${GATE_MARK:-}" = yes ] && { echo "not ok - tip case" >&2; echo "not ok - new case" >&2; exit 1; }; exit 0' t/a.test.sh
  refused 'a different red in the same script' worse 't/a.test.sh'
  # A lane that breaks a script that passes on the tip: blocked.
  lane breaks 'echo "not ok - broke c" >&2; exit 1' t/c.test.sh
  refused 'a script that passes on the tip' breaks 't/c.test.sh'
  # Reported once for the tip tree: one wake and one note, however many lanes met it; and the tip was rerun once.
  [ "$(grep -c . "$W/backlog-calls")" = 1 ] || fail "the tip's red must be noted once: $(cat "$W/backlog-calls")"
  [ "$(grep -c 'trunk-tip-red-proj-' "$HOME_D/state/.wake-queue")" = 1 ] || fail "the tip's red must raise one alert: $(cat "$HOME_D/state/.wake-queue" 2>&1)"
  assert_contains "$(cat "$W/backlog-calls")" "update ticket-red --append-notes" "the note goes to the red ticket"
  assert_contains "$(cat "$W/backlog-calls")" "t/a.test.sh" "the note names the red script"
  [ "$(grep -c '^t/a.test.sh' "$HOME_D/data/trunk/"tip-results-proj-*.tsv)" = 1 ] || fail "the tip's result for a script is computed once"
  assert_contains "$(cat "$HOME_D/data/trunk/tip-red-reported-proj.tsv")" "t/a.test.sh" "the report is recorded by script and tip tree"
  [ "$(tip)" = "$tipc" ] || fail "no refused lane moves the trunk"
  # A lane that touches only what is unrelated lands; the tip's red is set aside, not charged, and the green pin stays.
  lane good 'exit 0' t/d.test.sh
  green=$(cat "$HOME_D/state/trunk-green-proj")
  out=$(trunk land good 2>&1) || fail "a lane that adds no red must land on a red tip: $out"
  assert_contains "$out" "not charged to this lane" "the landing must say it set the tip's red aside"
  assert_contains "$out" "gate=full-tip-red" "the landing must record that the gate was set against the tip"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$green" ] || fail "a landing that set red aside must not move the green pin"
  [ "$(grep -c . "$W/backlog-calls")" = 1 ] && [ "$(grep -c 'trunk-tip-red-proj-' "$HOME_D/state/.wake-queue")" = 1 ] || fail "the same tip tree is not reported twice"
  pass 'the full gate blocks only what the lane broke: new, worse and broken-passing scripts block; the tip'"'"'s own red lands, reported once'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_flaky_failure_gets_one_rerun_before_it_is_judged() {
  local out green
  world flaky; rig; seed_red_tip; green=$(cat "$HOME_D/state/trunk-green-proj")
  # Fails the first time the gate runs it and passes the second: judged flaky, so the lane lands beside the tip's own red.
  lane once "[ -e $W/seen ] || { : > $W/seen; echo 'not ok - flaky case' >&2; exit 1; }; exit 0" t/f.test.sh
  out=$(trunk land once 2>&1) || fail "a failure that passes on its one rerun must not block: $out"
  assert_contains "$out" "judged flaky" "the landing must say it set a flaky failure aside"
  assert_contains "$out" "gate=full-tip-red" "the tip's own red is still set aside and recorded"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$green" ] || fail "a rerun landing must not move the green pin"
  # The same script failing on both runs is the lane's own failure.
  lane twice 'echo "not ok - solid case" >&2; exit 1' t/g.test.sh
  refused 'a failure that repeats on the rerun' twice 't/g.test.sh'
  pass 'a failure gets one rerun before it is judged: a flaky one is set aside, a repeated one blocks'
}

test_configured_hooks_and_the_launch_overlay_preserve_trunk_protection() {
  local c before out rc=0 hook_kind owner_hash
  for hook_kind in configured owner-guard; do
  rc=0
  world "hook-context-$hook_kind"
  lane hook good; c=$(git -C "$PROJ" rev-parse fm/hook); before=$(tip)
  mkdir -p "$W/repository-hooks"
  if [ "$hook_kind" = owner-guard ]; then
    sed -e 's/__NAME__/reference-transaction/g' -e "s|__CAT__|$(command -v cat)|g" \
      -e "s|__MKTEMP__|$(command -v mktemp)|g" -e "s|__RM__|$(command -v rm)|g" \
      "$ROOT/core/owner-guard/global-hook.sh" > "$W/repository-hooks/reference-transaction"
    chmod 555 "$W/repository-hooks/reference-transaction"
    owner_hash=$(git hash-object "$W/repository-hooks/reference-transaction")
  fi
  git -C "$PROJ" config core.hooksPath "$W/repository-hooks"
  "$ROOT/bin/jg-git-strip-ai-trailers.sh" install "$W/launch-hooks" "$PROJ"
  "$ROOT/bin/jg-git-strip-ai-trailers.sh" env-file "$W/launch-hooks" "$W/launch-env"
  # A real child shell inherits exactly the env-file entry the spawn path emits.
  (
    # shellcheck source=/dev/null # The real launch helper emitted this environment file.
    . "$W/launch-env"
    trunk due "$PROJ" >/dev/null 2>&1 || true
    [ "$(git -C "$PROJ" rev-parse --path-format=absolute --git-path hooks/reference-transaction)" = "$W/launch-hooks/reference-transaction" ] || fail "the launched environment lost its configured hook directory"
    out=$(git -C "$PROJ" update-ref refs/heads/trunk "$c" "$before" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "the task overlay bypassed the repository trunk guard"
    assert_contains "$out" 'moves only through' 'the actual configured hook must refuse the unauthorized movement'
    [ "$(tip)" = "$before" ] || fail "a refused transaction moved the trunk"
    trunk land hook >/dev/null 2>&1 || fail "the same configured hook must allow the guarded landing"
  ) || fail "configured hook journey failed"
  [ "$(tip)" = "$c" ] || fail "the authorized landing did not move the trunk"
  if [ "$hook_kind" = owner-guard ]; then
    [ "$(git hash-object "$W/repository-hooks/reference-transaction")" = "$owner_hash" ] || fail "the existing owner hook was changed"
  fi
  pass "the spawned Git environment preserves $hook_kind hooks and repository trunk protection"
  done
}

test_admission_is_shared_by_manual_and_automatic_requests() {
  local c out rc=0 first_log
  world admission
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  lane once BAD; c=$(git -C "$PROJ" rev-parse fm/once)
  printf 'gate-full=echo first >> "%s/calls"; while [ ! -e "%s/release" ]; do sleep 0.1; done; echo original; exit 1\n' "$W" "$W" >> "$HOME_D/config/trunk-policy"
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null
  for _ in $(seq 1 100); do [ ! -s "$W/calls" ] || break; sleep 0.1; done
  [ -s "$W/calls" ] || fail "automatic request did not enter its gate"
  out=$(trunk land once 2>&1) || rc=$?
  : > "$W/release" # release our own attempt even when the assertion below fails
  [ "$rc" = 75 ] || fail "a concurrent manual request must report in progress (75): $out"
  assert_contains "$out" IN_PROGRESS "a concurrent request must name its typed outcome"
  sweep >/dev/null
  first_log=$(find "$HOME_D/data/jg-trunk-landing" -name gate-full.log -print | head -n 1)
  out=$(trunk land once 2>&1) && fail "an unchanged failed gate must stay refused"
  [ "$(wc -l < "$W/calls" | tr -d ' ')" = 1 ] || fail "unchanged failure reran its gate"
  printf 'gate-full=echo second >> "%s/calls"; echo changed; exit 1\n' "$W" >> "$HOME_D/config/trunk-policy"
  trunk land once >/dev/null 2>&1 && fail "a changed failing context must refuse"
  [ "$(wc -l < "$W/calls" | tr -d ' ')" = 2 ] || fail "changed context must get one attempt"
  [ "$(cat "$first_log")" = original ] || fail "a later attempt overwrote the original gate log"
  [ "$(find "$HOME_D/data/jg-trunk-landing" -name gate-full.log | wc -l | tr -d ' ')" = 2 ] || fail "every attempt must keep its gate log"
  [ "$(tip)" != "$c" ] || fail "failed proof must never move the trunk"
  pass 'automatic/manual requests share admission, unchanged failure stays cached, and changed attempts retain their logs'
}

test_a_home_with_other_shas_is_contained_only_when_the_trunk_took_its_changes() {
  local g="$TMP_ROOT/contained" t m h rc=0 out
  jg_git_init_commit "$g"; commit_in "$g" a.txt one "base"; t=$(git -C "$g" rev-parse HEAD)
  git -C "$g" checkout -q -b home; commit_in "$g" a.txt two "home change"; commit_in "$g" b.txt new "home file"; h=$(git -C "$g" rev-parse HEAD)
  git -C "$g" checkout -q -b trunk2 "$t"; commit_in "$g" a.txt two "the trunk takes it as one squash"; commit_in "$g" b.txt new "squash part 2"
  commit_in "$g" a.txt three "a later trunk commit supersedes it"; m=$(git -C "$g" rev-parse HEAD)
  "$ROOT/bin/jg-home-contained.sh" "$h" "$m" "$g" || fail "a home whose changes are on the trunk (one later superseded) must be contained"
  "$ROOT/bin/jg-home-contained.sh" "$t" "$m" "$g" || fail "an ancestor of the trunk is contained"
  git -C "$g" checkout -q home; commit_in "$g" c.txt stray "stray commit"; h=$(git -C "$g" rev-parse HEAD)
  out=$("$ROOT/bin/jg-home-contained.sh" "$h" "$m" "$g") || rc=$?
  [ "$rc" = 1 ] || fail "a home with a change the trunk never took must exit 1, got $rc"
  assert_contains "$out" 'uncontained: c.txt' "the uncontained path must be named"
  case $out in *a.txt*|*b.txt*) fail "contained paths must not be listed: $out" ;; esac
  rc=0; "$ROOT/bin/jg-home-contained.sh" "$h" nope "$g" 2>/dev/null || rc=$?
  [ "$rc" = 2 ] || fail "an unknown commit must exit 2, got $rc"
  pass 'jg-home-contained proves tree containment: same bytes, a superseding trunk commit, or the named uncontained paths'
}

if [ "${JG_TRUNK_OUTER_ONLY:-0}" = 1 ]; then
  test_the_watcher_runs_the_landing_check_on_its_fast_tick
  exit
fi

test_configured_hooks_and_the_launch_overlay_preserve_trunk_protection
test_a_home_with_other_shas_is_contained_only_when_the_trunk_took_its_changes
test_admission_is_shared_by_manual_and_automatic_requests

test_legacy_mode_stays_interoperable
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_the_gates_are_policy_keys_with_fast_defaults() {
  local key
  pol() { JG_CONFIG_OVERRIDE="$TMP_ROOT/no-config" bash -c ". '$ROOT/bin/jg-trunk-policy-lib.sh'; jg_trunk_policy $1"; }
  assert_contains "$(pol gate-lint)" "--changed-base HEAD^" "the landing lint must cover the changed files only"
  assert_contains "$(pol gate-full)" "--changed --base HEAD^" "the landing tests must be the changed files' tests"
  case $(pol gate-full) in *"--all"*) fail "the landing must not run the whole suite" ;; esac
  assert_contains "$(pol gate-verify)" "bin/jg-test-run.sh --all" "verify must run the whole suite"
  for key in gate-mode gate-smoke owner-rules; do pol "$key" >/dev/null 2>&1 && fail "the retired policy key $key must be gone"; done
  pass 'the landing gates are policy keys: the lint and tests cover the changed files, the whole suite is verify'"'"'s'
}

test_a_landing_rebases_the_lane_by_itself_and_no_seal_blocks_it() {
  local out rows c1 c2 c3
  world rebase
  # The merge gate of this home refuses every merge for a missing signature: a landing no longer asks it.
  printf '#!/usr/bin/env bash\necho "merge refused: no valid local proof signature" >&2\nexit 1\n' > "$HOME_D/config/merge-gate"; chmod +x "$HOME_D/config/merge-gate"
  lane r1 one a.txt; lane r2 two b.txt; lane r3 three c.txt
  rm "$HOME_D/state/r1.run-receipt.json"; prove r2 FAIL
  c1=$(git -C "$PROJ" rev-parse fm/r1)
  out=$(trunk land r1 2>&1) || fail "a lane with no receipt must land: $out"
  [ "$(tip)" = "$c1" ] || fail "r1 must be on the trunk as it is"
  # r2 is based on the old tip: the lander rebases it, the lane follows, its worktree stays clean.
  c2=$(git -C "$PROJ" rev-parse fm/r2)
  out=$(trunk land r2 2>&1) || fail "a lane on a moved tip with a FAIL receipt must land by being rebased: $out"
  [ "$(tip)" != "$c2" ] && [ "$(git -C "$PROJ" rev-parse "$(tip)^")" = "$c1" ] || fail "the rebased commit must sit directly on the previous tip"
  [ "$(git -C "$PROJ" rev-parse fm/r2)" = "$(tip)" ] || fail "the lane must follow its rebased commit"
  [ -z "$(git -C "$W/lanes/r2" status --porcelain)" ] && [ "$(git -C "$W/lanes/r2" rev-parse HEAD)" = "$(tip)" ] || fail "the lane's worktree must follow the rebase and stay clean"
  [ "$(git -C "$PROJ" log -1 --format=%s "$(tip)")" = "ticket r2" ] || fail "the rebased commit must keep the lane's message"
  # A receipt for another head, and a lane whose worktree has unsaved work: both land.
  prove r3; git -C "$W/lanes/r3" -c user.name=t -c user.email=t@example.invalid commit -q --amend -m "ticket r3 amended"
  printf 'unsaved\n' > "$W/lanes/r3/scratch.txt"
  out=$(trunk land r3 2>&1) || fail "a receipt for another head must not block a landing: $out"
  c3=$(git -C "$PROJ" rev-parse fm/r3)
  [ "$(tip)" != "$c3" ] && [ -f "$W/lanes/r3/scratch.txt" ] || fail "unsaved work in the lane must be left exactly as it was"
  rows=$(cat "$HOME_D/data/trunk-landing-proofs.tsv")
  assert_contains "$rows" "$(printf 'r1\tproj\t%s' "$c1")" "the landing must be recorded with its facts"
  assert_contains "$rows" "receipt=absent" "a missing seal is recorded as absent"
  assert_contains "$rows" "receipt=FAIL@" "a failing seal is recorded, not enforced"
  assert_contains "$rows" "signature=absent" "a missing signature is recorded as absent"
  assert_contains "$rows" "merge-card=absent" "a missing merge-card is recorded as absent"
  mkdir -p "$HOME_D/data/r4/proof-authorizations"; lane r4 four d.txt; : > "$HOME_D/data/r4/proof-authorizations/$(git -C "$PROJ" rev-parse fm/r4).sig"
  trunk land r4 >/dev/null 2>&1 || fail "r4 must land"
  assert_contains "$(grep '^r4' "$HOME_D/data/trunk-landing-proofs.tsv")" "signature=present" "a signature that exists is recorded as present"
  # A change that really conflicts is still refused, with its paths, and is never rebased dirty.
  lane x1 left; lane x2 right
  trunk land x1 >/dev/null 2>&1 || fail "x1 must land"
  refused 'a conflicting lane' x2 'conflicts with trunk'
  assert_contains "$(trunk land x2 2>&1)" 'in: work.txt' 'a conflict names its paths'
  pass 'the lander rebases a lane by itself and the seal, the merge-card and the signature never block a landing'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_three_lanes_land_in_order_a_red_one_is_refused_and_a_post_land_red_is_reverted() {
  local base rc out sha n
  world journey; rig; base=$(tip)
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  # The landing gate is the fast check (work.txt); the whole suite runs after the landing (the rig runs t/*.test.sh).
  printf 'gate-full=! grep -q BAD work.txt\ngate-verify=bash %s/rig.sh --all\n' "$W" >> "$HOME_D/config/trunk-policy"
  # Four lanes are ready at once, on the same old tip; the second one is red.
  lane j1 'exit 0' t/j1.test.sh; lane j2 BAD; lane j3 'exit 0' t/j3.test.sh; lane j4 'exit 0' t/j4.test.sh
  out=$(JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D") || fail "the check must not fail: $out"
  for _ in $(seq 1 150); do [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" -ge 3 ] && ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && break; sleep 0.2; done
  n=$(git -C "$PROJ" rev-list --count "$base..trunk")
  [ "$n" = 3 ] || fail "three lanes must land with no human step, got $n: $(git -C "$PROJ" log --format=%s "$base..trunk")"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket j1,ticket j3,ticket j4" ] || fail "the lanes must land in the order they were done"
  for sha in $(git -C "$PROJ" rev-list "$base..trunk"); do [ "$(git -C "$PROJ" rev-list --parents -n 1 "$sha" | wc -w)" = 2 ] || fail "every landed commit must be one commit on the previous tip"; done
  [ "$(paste -sd, - < "$W/teardown-calls")" = "j1,j3,j4" ] || fail "each landed lane is cleaned up, unforced, in order, and the red one is kept: $(cat "$W/teardown-calls")"
  assert_contains "$(grep -c . "$HOME_D/data/trunk-landings.tsv")" 3 "three landings are logged"
  out=$(JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D")
  assert_contains "$out" "j2 not landed" "the red lane is refused and reported"
  assert_contains "$out" "gate 'full' failed" "the red lane's refusal names the failed check"
  [ -z "$(JG_HOME="$HOME_D" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D")" ] || fail "the refusal is reported once"
  [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = 3 ] || fail "the red lane must not have moved the trunk"
  # Each landing was followed by the whole suite at that commit: the pin has caught up with the tip.
  for _ in $(seq 1 150); do [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] && break; sleep 0.2; done
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] || fail "the whole suite must run after the landings and move the green pin to the tip"
  [ ! -e "$W/live-moves" ] || fail "nothing here may go live"
  # A commit that passes the landing check and breaks the whole suite: landed, then reverted by itself.
  lane j5 'echo "not ok - j5 breaks the suite" >&2; exit 1' t/j5.test.sh;
  lane j6 'exit 0' t/j6.test.sh
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null
  for _ in $(seq 1 300); do git -C "$PROJ" log --format=%B trunk | grep -q '^reverts: ' && break; sleep 0.2; done
  git -C "$PROJ" log --format=%B trunk | grep -q "^reverts: " || fail "a post-land red must be reverted by itself: $(cat "$HOME_D"/data/jg-trunk-landing/j5.*.verify.log 2>&1)"
  for _ in $(seq 1 150); do git -C "$PROJ" log --format=%s trunk | grep -q "^ticket j6" && break; sleep 0.2; done
  git -C "$PROJ" log --format=%s trunk | grep -q "^ticket j6" || fail "the lane after the red one must still land"
  git -C "$PROJ" log --format='%H %s' trunk | grep -q "ticket j5" || fail "the bad commit must stay in the history: the trunk only moves forward"
  git -C "$PROJ" cat-file -e "trunk:t/j5.test.sh" 2>/dev/null && fail "the bad commit's change must be undone on the tip"
  assert_contains "$(git -C "$PROJ" log -1 --format=%B "$(git -C "$PROJ" log --format=%H --grep='^reverts: ' -n 1 trunk)")" "reverts: " "the revert names the commit it undoes"
  assert_contains "$(cat "$W/backlog-calls")" "update j5 --append-notes" "the lane's ticket is told"
  assert_contains "$(cat "$HOME_D/state/.wake-queue")" "went red after it landed and was reverted by itself" "Overwatch is told"
  [ ! -e "$HOME_D/state/trunk-red-proj" ] || fail "a reverted red must not stop landings"
  # A revert that cannot apply cleanly writes the red pin instead, and landings stop except a fixes-red commit.
  lane k1 'echo "not ok - k1 breaks the suite" >&2; exit 1' t/k1.test.sh; trunk land k1 >/dev/null 2>&1 || fail "k1 must land by hand"
  lane k2 'exit 0' t/k1.test.sh; git -C "$W/lanes/k2" reset -q --hard trunk; commit_in "$W/lanes/k2" t/k1.test.sh 'echo "not ok - k1 breaks the suite" >&2; echo more; exit 1' "ticket k2"
  trunk land k2 >/dev/null 2>&1 || fail "k2 must land by hand"
  rc=0; out=$(JG_HOME="$HOME_D" trunk verify "$PROJ" "$(git -C "$PROJ" log --format=%H --grep='ticket k1' -n 1 trunk)" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] && [ -e "$HOME_D/state/trunk-red-proj" ] || fail "a revert that does not apply must write the red pin: $out"
  assert_contains "$out" "could not be reverted by itself" "the red must say it could not be undone"
  pass 'three lanes land in order with no human step, the red lane is refused, and a post-land red is reverted'
}

test_a_good_lane_lands_but_goes_live_only_on_his_word
test_the_bundled_hook_moves_a_home_that_runs_the_project
test_every_unsafe_landing_refuses
test_a_seam_is_the_only_place_behaviour_changes
test_a_landing_is_pinned_behind_until_verify_passes
test_the_release_is_one_pr_from_the_trunk_on_his_word
test_a_red_ci_pins_the_home_back_to_the_last_green_commit
test_the_trunk_stays_safe_until_its_release_lands_then_the_next_version_is_cut
test_the_old_trunk_is_cleaned_up_unforced_and_only_when_its_work_is_carried
test_the_registered_check_lands_a_proved_task_without_a_human
test_the_landing_check_cuts_the_next_trunk_once_the_release_merged
test_the_watcher_runs_the_landing_check_on_its_fast_tick
test_the_full_gate_charges_a_lane_only_for_what_it_broke
test_a_flaky_failure_gets_one_rerun_before_it_is_judged
test_the_gates_are_policy_keys_with_fast_defaults
test_a_landing_rebases_the_lane_by_itself_and_no_seal_blocks_it
test_three_lanes_land_in_order_a_red_one_is_refused_and_a_post_land_red_is_reverted
printf 'jg-trunk: ok\n'
