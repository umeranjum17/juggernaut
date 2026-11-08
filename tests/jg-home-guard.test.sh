#!/usr/bin/env bash
# Integration test for bin/jg-home-guard.sh: the reference-transaction guard that lets a home's `main` and
# detached HEAD move only along the local trunk (ap-k1-code-truth, slice T3). Real git repositories throughout.
#
# T1 install writes a self-contained hook and records the trunk tip; `check` reports it present; install is idempotent
#    and `uninstall` (the rollback) removes it. A hook that is not ours is never overwritten.
# T2 A hand commit on `main`, `update-ref refs/heads/main <non-trunk>`, a checkout to a non-trunk commit (detached or
#    by branch) and a delete of `main` are refused with the reason; the refused move leaves the ref where it was.
# T3 Moves along the trunk pass: a fast-forward to a trunk commit, a checkout of a trunk commit, any commit in a pool
#    worktree on a lane branch, and origin/main after a release (a merge whose parents are all on the trunk).
# T4 The live path (JG_TRUNK_LIVE=1) admits a fast-forward to a newer trunk tip and the contained re-point of a
#    diverged home whose whole tree the new tip already holds; a divergence that would drop content refuses.
# T5 The pin-back (JG_TRUNK_PINBACK=1) admits one move to the HEAD recorded before the last live move, from the
#    guard's own record or a trunk-live.tsv row, and refuses a move to any other commit.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-home-guard)
GUARD="$ROOT/bin/jg-home-guard.sh"

# The machine-wide hooks path would hide the repository's own reference-transaction hook, so every git call here ignores it.
g() { env GIT_CONFIG_COUNT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid git "$@"; }
# ge KEY=VAL... -- <git args>: git with extra environment (the writer flags), for use under `refused`.
ge() { local -a e=(); while [ "${1-}" != -- ]; do e+=("$1"); shift; done; shift; env "${e[@]}" GIT_CONFIG_COUNT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
guard() { env GIT_CONFIG_COUNT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$GUARD" "$@"; }
commit() {  # <repo> <file> <content> <message>
  printf '%s\n' "$3" > "$1/$2"; g -C "$1" add "$2"; g -C "$1" commit -q -m "$4"
}

# world <name>: sets H (a home repo on main at trunk commit T1, trunk branch at T2) with the guard NOT yet installed.
world() {
  W="$TMP_ROOT/$1"; H="$W/home"; mkdir -p "$W"
  g init -q -b main "$H"
  commit "$H" base.txt base "B0"
  commit "$H" a.txt one "T1"; T1=$(g -C "$H" rev-parse HEAD)
  g -C "$H" branch trunk
  g -C "$H" checkout -q trunk
  commit "$H" a.txt two "T2"; T2=$(g -C "$H" rev-parse HEAD)
  g -C "$H" checkout -q main
}
hand_commit() { printf hand > "$H/h.txt"; g -C "$H" add h.txt; g -C "$H" commit -q -m hand; }
# park_main <sha>: put main on <sha> by hand with the guard out of the way, then guard the home again.
park_main() { guard uninstall "$H" >/dev/null 2>&1; g -C "$H" update-ref refs/heads/main "$1"; g -C "$H" reset -q --hard main; guard install "$H" --tip "$T2" >/dev/null 2>&1 || fail "install"; }
tip_of() { cat "$(g -C "$H" rev-parse --path-format=absolute --git-common-dir)/jg-home-guard/trunk-tip" 2>/dev/null; }
# refused <label> <expect> <command...>: the command must fail, say <expect>, and leave main where it was.
refused() {
  local label=$1 expect=$2 before out rc=0; shift 2
  before=$(g -C "$H" rev-parse refs/heads/main)
  out=$("$@" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "$label must be refused, but it passed"
  assert_contains "$out" "$expect" "$label must say why"
  [ "$(g -C "$H" rev-parse refs/heads/main)" = "$before" ] || fail "$label moved main although it was refused"
}

test_install_check_and_uninstall() {
  local out hook
  world install
  guard check "$H" >/dev/null 2>&1 && fail "check must report a missing guard"
  out=$(guard check "$H" 2>&1); assert_contains "$out" "missing" "check must name the missing guard"
  guard install "$H" --tip "$T2" >/dev/null 2>&1 || fail "install must work"
  hook="$H/.git/hooks/reference-transaction"
  [ -x "$hook" ] || fail "install must write an executable reference-transaction hook"
  assert_equals "$T2" "$(tip_of)" "install must record the trunk tip"
  out=$(guard check "$H" 2>&1) || fail "check must pass after install: $out"
  assert_contains "$out" "present" "check must say present"
  guard install "$H" --tip "$T2" >/dev/null 2>&1 || fail "install must be idempotent"
  guard install "$H" >/dev/null 2>&1 || fail "install without --tip takes the home's HEAD"
  assert_equals "$T1" "$(tip_of)" "install without --tip must record the home's HEAD as the tip"
  guard uninstall "$H" >/dev/null 2>&1 || fail "uninstall must work"
  [ ! -e "$hook" ] || fail "uninstall must remove the hook"
  printf '#!/bin/sh\nexit 0\n' > "$hook"; chmod +x "$hook"
  out=$(guard install "$H" 2>&1) && fail "install must not overwrite a hook that is not ours"
  assert_contains "$out" "not the home guard" "the refusal must say whose hook is in the way"
  [ "$(cat "$hook")" = $'#!/bin/sh\nexit 0' ] || fail "a foreign hook must be left as it was"
  pass 'install writes a self-contained hook and records the tip; check, idempotence, uninstall and a foreign hook behave'
}

test_a_hand_move_of_main_is_refused() {
  local lone
  world hand
  guard install "$H" --tip "$T2" >/dev/null 2>&1 || fail "install"
  # a commit that is on no trunk
  g -C "$H" checkout -q -b scratch main; commit "$H" x.txt hand "hand"; lone=$(g -C "$H" rev-parse HEAD); g -C "$H" checkout -q main
  refused "update-ref of main to a non-trunk commit" "not on the trunk" g -C "$H" update-ref refs/heads/main "$lone"
  refused "a hand commit on main" "not on the trunk" hand_commit
  g -C "$H" reset -q --hard main
  refused "a delete of main" "never deleted" g -C "$H" update-ref -d refs/heads/main
  refused "a checkout to a non-trunk commit" "not on the trunk" g -C "$H" checkout -q --detach "$lone"
  [ "$(g -C "$H" symbolic-ref -q HEAD)" = refs/heads/main ] || fail "a refused checkout must leave HEAD on main"
  pass 'a hand commit, update-ref, delete and checkout to a non-trunk commit are refused with the reason and move nothing'
}

test_moves_along_the_trunk_pass() {
  local out m
  world along
  guard install "$H" --tip "$T2" >/dev/null 2>&1 || fail "install"
  g -C "$H" merge -q --ff-only trunk || fail "a fast-forward to the trunk tip must pass"
  assert_equals "$T2" "$(g -C "$H" rev-parse main)" "main must be at the trunk tip"
  g -C "$H" update-ref refs/heads/main "$T1" || fail "a move of main to a trunk ancestor must pass"
  g -C "$H" checkout -q --detach "$T2" || fail "a checkout of a trunk commit must pass"
  g -C "$H" checkout -q main || fail "a checkout of main at a trunk commit must pass"
  # a pool worktree on a lane branch: any commit there is not the home's business
  g -C "$H" worktree add -q -b fm/lane "$W/lane" main || fail "worktree add"
  commit "$W/lane" lane.txt lane "lane work" || fail "a commit on a lane branch must pass"
  g -C "$W/lane" checkout -q --detach || fail "a lane worktree may detach"
  commit "$W/lane" lane2.txt lane2 "lane detached" || fail "a detached commit in a pool worktree must pass"
  # the release: origin/main becomes a merge whose parents are all on the trunk
  g -C "$H" update-ref refs/heads/main "$T1"
  g clone -q --bare "$H" "$W/origin.git"
  g clone -q "$W/origin.git" "$W/rel"
  g -C "$W/rel" checkout -q -b rel "$T1"; g -C "$W/rel" merge -q --no-ff -m "Merge pull request #1 from trunk" "$T2" 2>/dev/null || {
    g -C "$W/rel" fetch -q origin trunk && g -C "$W/rel" merge -q --no-ff -m "Merge pull request #1 from trunk" FETCH_HEAD; }
  m=$(g -C "$W/rel" rev-parse HEAD)
  g -C "$W/rel" push -q "$W/origin.git" "rel:main" -f
  g -C "$H" remote add origin "$W/origin.git"
  out=$(g -C "$H" pull -q --ff-only origin main 2>&1) || fail "origin/main after a release (a merge of trunk commits) must pass: $out"
  assert_equals "$m" "$(g -C "$H" rev-parse main)" "main must be at the release merge"
  # a merge with a commit that is not on the trunk is not a release
  g -C "$H" update-ref refs/heads/main "$T1"
  g -C "$H" checkout -q -b other main; commit "$H" o.txt o "other"; g -C "$H" checkout -q main
  refused "a hand merge with a non-trunk commit" "not on the trunk" g -C "$H" merge -q --no-ff -m hand other
  pass 'fast-forward, trunk checkout, pool-worktree commits and a release merge pass; a merge with a non-trunk parent refuses'
}

test_the_live_path_admits_a_newer_tip_and_a_contained_repoint() {
  local lone t3 t4 t5 out
  world live
  # a hand commit adds y.txt on main; the trunk later holds the same content in a squash
  g -C "$H" checkout -q -b scratch main; commit "$H" y.txt why "hand y"; lone=$(g -C "$H" rev-parse HEAD)
  g -C "$H" checkout -q main
  g -C "$H" checkout -q trunk; commit "$H" y.txt why "T3 holds y"; t3=$(g -C "$H" rev-parse HEAD)
  commit "$H" z.txt zed "T4"; t4=$(g -C "$H" rev-parse HEAD)
  g -C "$H" checkout -q -b elsewhere "$T2"; commit "$H" y.txt DIFFERENT "T5 has another y"; t5=$(g -C "$H" rev-parse HEAD)
  g -C "$H" checkout -q main
  guard install "$H" --tip "$T2" >/dev/null 2>&1 || fail "install"
  # a newer trunk tip is not yet the recorded one: refused by hand, admitted by the live path
  refused "a move to a trunk commit newer than the recorded tip" "not on the trunk" g -C "$H" update-ref refs/heads/main "$t4"
  JG_TRUNK_LIVE=1 g -C "$H" merge -q --ff-only "$t4" || fail "the live path must fast-forward to a newer trunk tip"
  assert_equals "$t4" "$(tip_of)" "the live move must record the new trunk tip"
  g -C "$H" update-ref refs/heads/main "$T1" || fail "after the live move the recorded tip admits its ancestors by hand"
  # the contained re-point: the home holds a hand commit whose whole content the new tip has
  park_main "$lone"
  JG_TRUNK_LIVE=1 g -C "$H" reset -q --keep "$t3" || fail "the live path must re-point a home whose tree the tip holds"
  assert_equals "$t3" "$(g -C "$H" rev-parse main)" "main must be re-pointed at the trunk commit"
  # a divergence that drops content is not a re-point
  park_main "$lone"
  out=$(JG_TRUNK_LIVE=1 g -C "$H" reset -q --keep "$t5" 2>&1) && fail "a re-point that drops the home's content must refuse"
  assert_contains "$out" "drop" "the refusal must say content would be dropped"
  assert_equals "$lone" "$(g -C "$H" rev-parse main)" "a refused re-point must leave main"
  # JG_TRUNK_TIP bounds the live path to the tip it names
  refused "a live move beyond the tip the live path named" "not on the trunk" ge JG_TRUNK_LIVE=1 JG_TRUNK_TIP="$t3" -- -C "$H" update-ref refs/heads/main "$t4"
  pass 'the live path admits a newer tip and a contained re-point, records the tip, and refuses a re-point that drops content'
}

test_the_pinback_admits_only_the_recorded_pre_move_head() {
  local lone t3 other out
  world pin
  g -C "$H" checkout -q -b scratch main; commit "$H" y.txt why "hand y"; lone=$(g -C "$H" rev-parse HEAD)
  g -C "$H" checkout -q -b scratch2 main; commit "$H" q.txt q "hand q"; other=$(g -C "$H" rev-parse HEAD)
  g -C "$H" checkout -q trunk; commit "$H" y.txt why "T3 holds y"; t3=$(g -C "$H" rev-parse HEAD)
  g -C "$H" checkout -q main
  park_main "$lone"
  JG_TRUNK_LIVE=1 g -C "$H" reset -q --keep "$t3" || fail "the first live move (a re-point) must pass"
  # a pin-back to any other commit refuses; without the flag a move to the pre-move HEAD refuses too
  refused "a pin-back to a commit that is not the recorded pre-move HEAD" "pre-move" ge JG_TRUNK_PINBACK=1 -- -C "$H" reset -q --keep "$other"
  refused "a move to the pre-move HEAD without the pin-back flag" "not on the trunk" g -C "$H" reset -q --keep "$lone"
  JG_TRUNK_PINBACK=1 g -C "$H" reset -q --keep "$lone" || fail "a pin-back to the recorded pre-move HEAD must pass"
  assert_equals "$lone" "$(g -C "$H" rev-parse main)" "the home must be back at its pre-move HEAD"
  # the same pin-back, admitted by a trunk-live.tsv row instead of the guard's own record
  mkdir -p "$W/data"
  JG_TRUNK_LIVE=1 g -C "$H" reset -q --keep "$t3" || fail "second live move"
  rm -f "$H/.git/jg-home-guard/pre-move"
  refused "a pin-back with no record of the move" "pre-move" ge JG_TRUNK_PINBACK=1 -- -C "$H" reset -q --keep "$lone"
  printf 'proj:primary\t%s\t1\tlive,re-pointed-from:x\t%s\n' "$t3" "$lone" > "$W/data/trunk-live.tsv"
  out=$(JG_DATA_OVERRIDE="$W/data" JG_TRUNK_PINBACK=1 g -C "$H" reset -q --keep "$lone" 2>&1) || fail "a row of trunk-live.tsv must admit the pin-back: $out"
  assert_equals "$lone" "$(g -C "$H" rev-parse main)" "the row-admitted pin-back must move the home"
  pass 'a pin-back passes only to the recorded pre-move HEAD (guard record or trunk-live.tsv row) and refuses any other commit'
}

test_install_check_and_uninstall
test_a_hand_move_of_main_is_refused
test_moves_along_the_trunk_pass
test_the_live_path_admits_a_newer_tip_and_a_contained_repoint
test_the_pinback_admits_only_the_recorded_pre_move_head
