#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh: the landing and release flow end to end against real git repositories,
# a local bare origin, the real gate chain and a stub for the captain-hold reader (tests/jg-trunk-fixture.sh).
# The check and going live are tests/jg-trunk-live.test.sh, the landing gate and the proof are tests/jg-trunk-gate.test.sh,
# the merge queue is tests/jg-trunk-queue.test.sh, and verify and the trunk lock are tests/jg-trunk-verify.test.sh.
# Through tests/jg-trunk-fixture.sh it runs bin/jg-trunk.sh, reads bin/jg-dod-lib.sh and stands in for bin/jg-captain-hold.sh,
# bin/jg-backlog.sh, bin/jg-send.sh, bin/jg-teardown.sh, bin/jg-fleet-ledger.sh and bin/jg-home-health.sh.
#
# T1 A one-commit lane lands on the trunk by compare-and-swap and is logged, but landing never goes live: live
#    refuses without the captain's recorded word, runs the hook at the green commit with it, and spends the word.
#    The landing's own gate moves the green pin; a red a hand-run verify finds later pins the home behind it.
# T2 Every unsafe landing refuses and leaves the trunk where it was: a second commit, a conflicting change (it names its
#    paths), a failing gate, a failing lint, an owner-guard hit, away mode, a ref a lane moved, a
#    decision still open on linked work, a protected path, and a commit with no ticket reference.
# T3 The seams are the only place behaviour changes: protected-landing=gate and away-landing=allowed
#    let the same commits land, with no code change; the gate commands are policy keys with fast defaults.
# T5 The release is ONE PR from the trunk itself into the default branch: no release branch, no
#    force, refused without the captain's word, and a second release while it is open opens no
#    second PR; an empty batch refuses and a published batch can retry its proof.
# T8 Only the lander moves the trunk: a hand write to it is refused by the hook the trunk installs;
#    land records the same merged event as the local merge. A home guard (bin/jg-home-guard.sh) installed in the same
#    repository chains the trunk guard: both still refuse, reruns and a landing change neither hook, uninstall restores it.
# T5b A release (and the word for it) carries the last green commit while the tip is ahead of it; with no green recorded it refuses.
# T9 The trunk is safe until its release PR lands: no write rewinds, forces or deletes it, even the lander's
#    own; once the release merged, the next trunk version (trunk-v2) is cut from the default branch, recorded,
#    and landed on, with the old trunk untouched; while it is open, nothing rolls over.
# T10 Once the next trunk is cut, the old one is cleaned up unforced - remote branch, local branch, worktrees - only
#    when its release is proved on main and every hotfix is carried into the new trunk; a copy holding
#    unlanded work, or a hotfix not carried, keeps it, listed.
# T16 A lander refusal the worker fixes reaches that lane's worker by itself: a steer carrying the refusal text, repeated while the
#    head is unchanged and the worker has no unread steer, never for a head the lane no longer has or for a refusal that only needs
#    time; a refusal nobody acted on for ten minutes raises one alert naming the lane; the done and the steer name what to run.
# T6 A red CI pins the home back to the last green live commit and stops landings; a worker
#    cannot record the captain's word.
# The done-done journey journeys/trunk-landing.sh runs this file and seals its output.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

sends() { awk -F'\t' -v i="$1" '$1 == i { n++ } END { print n + 0 }' "$W/send-calls" 2>/dev/null || echo 0; }

# moved_world <name>: byokit's shape. Lanes l1 and l2 landed; then the trunk branch is set by hand (no hook, as on the real home) to a
# commit M of origin/main that lacks them. Lane c holds one commit on M whose tree is the merge of the old record and M.
moved_world() {
  local base m
  world "$1"
  base=$(tip); lane l1 one l1.txt; lane l2 two l2.txt
  trunk land l1 >/dev/null 2>&1 || fail "l1 must land"; trunk land l2 >/dev/null 2>&1 || fail "l2 must land"
  OLD=$(tip); printf '%s\n' "$OLD" > "$HOME_D/state/trunk-green-proj"  # verify passed on the last landing
  git -C "$PROJ" worktree add -q --detach "$W/main-wt" "$base"; commit_in "$W/main-wt" main.txt m "main moves"
  M=$(git -C "$W/main-wt" rev-parse HEAD); git -C "$PROJ" push -q origin "$M:refs/heads/main"
  rm -f "$PROJ/.git/hooks/reference-transaction"; plain_git -C "$PROJ" update-ref refs/heads/trunk "$M" "$OLD"
  C=$(git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit-tree "$(git -C "$PROJ" merge-tree --write-tree "$OLD" "$M")" -p "$M" -m "ticket c")
  git -C "$PROJ" branch -f fm/c "$C"; jg_write_meta "$HOME_D/state/c.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/c"
  prove c; ready c
}
rows_of() { grep -c "" "$HOME_D/data/trunk-adoptions.tsv" 2>/dev/null || echo 0; }

# adopt-tip ends a trunk the lander did not leave: (a) byokit's shape, with the lost commits listed and carried by a lane, (b) pockit's
# shape, (c) an unexplained move, (d) a worker, (e) the wait class and the one wake naming the command.
test_adopt_tip_ends_a_moved_trunk_with_a_record_and_loses_no_landed_commit() {
  local out
  moved_world adopt-a
  # (e) before any adoption: every subcommand refuses, the class is wait, and one wake names the command.
  out=$(trunk land c 2>&1) && fail "a moved trunk must refuse a landing: $out"
  assert_contains "$out" 'something else moved it' 'the refusal keeps its phrase'
  printf '%s\n' "$out" > "$W/moved.out"; [ "$(trunk classify "$W/moved.out")" = wait ] || fail "the moved-trunk refusal must be class wait"
  trunk land c >/dev/null 2>&1 || :
  trunk land c >/dev/null 2>&1 || :
  [ "$(grep -c "trunk-moved-proj-${OLD:0:12}-${M:0:12}" "$HOME_D/state/.wake-queue")" = 1 ] || fail "one wake, keyed by record and branch, however many refusals: $(cat "$HOME_D/state/.wake-queue" 2>&1)"
  grep -q "adopt-tip $PROJ --reason .* --carried-by <task-id>" "$HOME_D/state/.wake-queue" || fail "the wake names the exact adopt-tip line and the lane the lost commits need"
  # (a) the lost commits are listed and refused without --carried-by.
  out=$(trunk adopt-tip "$PROJ" --reason 'main moved by a fetch' 2>&1) && fail "lost commits without --carried-by must be refused: $out"
  assert_contains "$out" '2 landed commit' 'the refusal counts the lost commits'; assert_contains "$out" 'ticket l1' 'the refusal lists them'
  [ "$(cat "$HOME_D/state/trunk-tip-proj")" = "$OLD" ] || fail "a refused adoption leaves the record"
  # A lane that is not the merge is refused.
  git -C "$PROJ" branch -f fm/bad "$M"; jg_write_meta "$HOME_D/state/bad.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/bad"
  out=$(trunk adopt-tip "$PROJ" --reason r --carried-by bad 2>&1) && fail "a lane that is not one commit on the tip must be refused: $out"
  assert_contains "$out" 'exactly one commit' 'the lane shape is named'
  # The adoption with the carrying lane.
  trunk adopt-tip "$PROJ" --reason 'main moved by a fetch' --carried-by c >/dev/null || fail "the carrying lane must allow the adoption"
  [ "$(cat "$HOME_D/state/trunk-tip-proj")" = "$M" ] || fail "the record follows the tip"
  [ "$(git -C "$PROJ" for-each-ref --format='%(objectname)' 'refs/jg/trunk-adopted/trunk/')" = "$OLD" ] || fail "a keep ref holds the old record"
  [ "$(rows_of)" = 1 ] || fail "one row per adoption"
  grep -q "^proj	$OLD	$M	[0-9]*	on-default	2	c	main moved by a fetch\$" "$HOME_D/data/trunk-adoptions.tsv" || fail "the row must carry both commits, the relation, the lost count, the lane and the reason: $(cat "$HOME_D/data/trunk-adoptions.tsv")"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$M" ] || fail "an on-default adoption moves a green pin that is not behind the tip to the tip"
  out=$(trunk land c 2>&1) || fail "the carrying lane lands once the tip is adopted: $out"
  [ "$(git -C "$PROJ" show trunk:l1.txt)" = one ] && [ "$(git -C "$PROJ" show trunk:main.txt)" = m ] || fail "the landed commits and main's are all on the trunk"
  out=$(trunk adopt-tip "$PROJ" --reason again 2>&1) || :
  [ "$(rows_of)" = 1 ] || fail "an adoption at a record that stands writes nothing more"
  pass 'adopt-tip refuses landed commits left off the trunk, adopts with the carrying lane, keeps the old record, writes one row, and the lane lands'
}

# A landing sees a forward move from another home and records it without a model turn.
test_landing_adopts_forward_and_refuses_rewind() {
  local old new out
  world auto-adopt
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  old=$(tip)
  lane first one first.txt; trunk land first >/dev/null 2>&1 || fail "first lane must land"
  new=$(tip)
  printf '%s\n' "$old" > "$HOME_D/state/trunk-tip-proj"
  sweep >/dev/null
  [ "$(cat "$HOME_D/state/trunk-tip-proj")" = "$new" ] || fail "idle forward trunk must be adopted by the landing check"
  grep -q "^proj	$old	$new	[0-9]*	forward	0	-	" "$HOME_D/data/trunk-adoptions.tsv" || fail "adoption row must name both tips and the reason"
  lane next two next.txt; sweep >/dev/null
  [ "$(tip)" = "$(git -C "$PROJ" rev-parse fm/next)" ] || fail "a lane must land after adoption"
  old=$(tip)
  git -C "$PROJ" -c core.hooksPath=/dev/null update-ref refs/heads/trunk "$new" "$old"
  rm -f "$HOME_D/data/jg-trunk-landing/.green-alarm-proj"
  sweep >/dev/null
  grep -q "trunk-moved-proj-${old:0:12}-${new:0:12}" "$HOME_D/state/.wake-queue" || fail "idle rewind must alarm"
  lane rewind three rewind.txt
  sweep >/dev/null
  out=$(cat "$HOME_D"/data/jg-trunk-landing/rewind.*.state)
  assert_contains "$out" 'something else moved it' 'rewind must alarm'
  [ "$(cat "$HOME_D/state/trunk-tip-proj")" = "$old" ] || fail "rewind must not change the record"
  world auto-release
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  old=$(tip); lane released one release.txt; trunk land released >/dev/null 2>&1 || fail "released lane must land"
  new=$(tip); printf '%s\n' "$old" > "$HOME_D/state/trunk-tip-proj"
  printf '%s\n' "$new" > "$HOME_D/state/trunk-released-proj"
  sweep >/dev/null
  [ "$(cat "$HOME_D/state/trunk-tip-proj")" = "$new" ] || fail "released forward tip must be adopted"
  grep -q "^proj	$old	$new	[0-9]*	forward	0	-	" "$HOME_D/data/trunk-adoptions.tsv" || fail "released adoption must be recorded"
  pass 'landing adopts forward and released tips and refuses a rewind'
}

test_adopt_tip_takes_a_forward_move_and_refuses_an_unexplained_one_a_worker_and_any_flag() {
  local out stray
  world adopt-b
  lane b1 one b1.txt; trunk land b1 >/dev/null 2>&1 || fail "b1 must land"
  lane b2 two b2.txt; trunk land b2 >/dev/null 2>&1 || fail "b2 must land"
  # Each landing moves the green pin to its head, so the record and the pin go back by hand: b1 and b2 stand for commits another home put on the trunk, which no gate here judged.
  printf '%s\n' "$(git -C "$PROJ" rev-parse trunk~2)" > "$HOME_D/state/trunk-tip-proj"
  printf '%s\n' "$(git -C "$PROJ" rev-parse trunk~2)" > "$HOME_D/state/trunk-green-proj"
  # (d) a worker never adopts; no force or skip flag exists; a reason is required.
  out=$(JG_TASK_ID=b1 trunk adopt-tip "$PROJ" --reason x 2>&1) && fail "a worker must be refused: $out"
  assert_contains "$out" 'worker never adopts' 'the worker is refused by name'
  for flag in --force --skip --no-verify; do out=$(trunk adopt-tip "$PROJ" "$flag" --reason x 2>&1) && fail "$flag must be refused: $out"; done
  out=$(trunk adopt-tip "$PROJ" --reason '  ' 2>&1) && fail "a blank reason must be refused: $out"
  [ "$(rows_of)" = 0 ] || fail "a refused adoption writes no row"
  # (b) pockit's shape: the record is an ancestor of the tip, which is not on origin/main: forward, lost 0.
  trunk adopt-tip "$PROJ" --reason 'fetched from another home' >/dev/null || fail "a forward move must be adopted"
  [ "$(cat "$HOME_D/state/trunk-tip-proj")" = "$(tip)" ] || fail "the record follows the tip"
  grep -q "	forward	0	-	fetched from another home\$" "$HOME_D/data/trunk-adoptions.tsv" || fail "the row names the relation and no lost commit"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(git -C "$PROJ" rev-parse trunk~2)" ] || fail "a forward adoption does not move the green pin to a commit no gate judged"
  # (c) neither on origin/main nor holding the record: refused.
  stray=$(git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit-tree "$(git -C "$PROJ" hash-object -t tree /dev/null)" -m stray)
  printf '%s\n' "$stray" > "$HOME_D/state/trunk-tip-proj"
  out=$(trunk adopt-tip "$PROJ" --reason 'someone moved it' 2>&1) && fail "an unexplained move must be refused: $out"
  assert_contains "$out" 'not explained' 'the refusal says the move is not explained'
  [ "$(cat "$HOME_D/state/trunk-tip-proj")" = "$stray" ] || fail "a refused adoption leaves the record"
  pass 'adopt-tip adopts a forward move, and refuses an unexplained move, a worker, any flag and a blank reason'
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

test_a_repaired_hook_overlay_admits_exactly_one_fresh_attempt() {
  local out n
  world hook-repair
  lane fix good
  mkdir -p "$W/repository-hooks"
  printf '#!/bin/sh\nexit 0\n' > "$W/repository-hooks/reference-transaction"; chmod 755 "$W/repository-hooks/reference-transaction"
  git -C "$PROJ" config core.hooksPath "$W/repository-hooks"
  out=$(trunk land fix 2>&1) && fail "an unrecognized effective hook must refuse the landing"
  assert_contains "$out" 'is not the trunk guard' 'the hook refusal must name its cause'
  n=$(find "$HOME_D/data/jg-trunk-landing" -name 'fix.*.attempt-*' | wc -l | tr -d ' ')
  trunk land fix >/dev/null 2>&1 && fail "an unchanged hook refusal must stay refused"
  trunk land fix >/dev/null 2>&1 && fail "a repeated unchanged check must stay refused"
  [ "$(find "$HOME_D/data/jg-trunk-landing" -name 'fix.*.attempt-*' | wc -l | tr -d ' ')" = "$n" ] || fail "an unchanged hook must not admit another attempt"
  # The overlay is repaired: the effective hook now chains the repository's own guard.
  # shellcheck disable=SC2016 # the delegate hook body is written out verbatim
  printf '#!/bin/sh\n# managed by bin/jg-trunk.sh: delegate to the repository trunk guard\ncommon=$(git rev-parse --path-format=absolute --git-common-dir) || exit 1\nhook=$common/hooks/reference-transaction\n[ ! -x "$hook" ] || exec "$hook" "$@"\nexit 0\n' > "$W/repository-hooks/reference-transaction"
  trunk land fix >/dev/null 2>&1 || fail "a repaired hook overlay must admit one fresh attempt that lands"
  [ "$(find "$HOME_D/data/jg-trunk-landing" -name 'fix.*.attempt-*' | wc -l | tr -d ' ')" = $((n + 1)) ] || fail "a repaired hook must admit exactly one new attempt"
  pass 'a changed effective hook overlay admits exactly one fresh attempt, and an unchanged refusal is not repeated'
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

test_legacy_mode_stays_interoperable() {
  world legacy
  lane old one
  sed -i 's/^mode=local-trunk$/mode=local-only/' "$HOME_D/state/old.meta"
  sed -i 's/"mode":"local-trunk"/"mode":"local-only"/' "$HOME_D/state/old.run-receipt.json"
  trunk land old >/dev/null 2>&1 || fail "legacy local-only records must still land"
  grep -qx mode=local-only "$HOME_D/state/old.meta" || fail "legacy records must not be rewritten"
  pass 'a legacy local-only record lands without a mode rewrite'
}

# The live move's real failure: a home that is also the local-trunk project holds the trunk guard in the hook file, so the
# home guard install refused it and the home was rolled back. The home guard now chains the trunk guard: both refuse what they
# refused alone, a rerun of either installer and a landing change neither file, and uninstall gives the trunk guard its file back.
test_the_home_guard_chains_the_trunk_guard() {
  local hook trunk_hook out before both lone c
  world home-guard-chain
  hook=$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir)/hooks/reference-transaction
  grep -q '^# managed by bin/jg-trunk.sh:' "$hook" || fail "trunk init must have installed the trunk guard"
  trunk_hook=$(cat "$hook")
  out=$("$W/root/bin/jg-home-guard.sh" install "$PROJ" 2>&1) || fail "the home guard must install beside the trunk guard: $out"
  assert_contains "$out" "it runs the trunk guard first" "the install must say it chained the trunk guard"
  [ "$(cat "$hook.chained")" = "$trunk_hook" ] || fail "the trunk guard must be kept, byte for byte, in the chained slot"
  "$W/root/bin/jg-home-guard.sh" check "$PROJ" >/dev/null || fail "the home guard must be present"
  both=$(cat "$hook" "$hook.chained" | git hash-object --stdin)
  "$W/root/bin/jg-home-guard.sh" install "$PROJ" >/dev/null || fail "a second install must pass"
  [ "$(cat "$hook" "$hook.chained" | git hash-object --stdin)" = "$both" ] || fail "a second install must change neither hook"
  git -C "$PROJ" checkout -q -b scratch main; commit_in "$PROJ" scratch.txt x "off the trunk"; lone=$(git -C "$PROJ" rev-parse HEAD); git -C "$PROJ" checkout -q main
  before=$(tip); out=$(plain_git -C "$PROJ" update-ref refs/heads/trunk "$lone" 2>&1) && fail "a hand move of the trunk must stay refused"
  assert_contains "$out" "moves only through bin/jg-trunk.sh land" "the trunk guard must still judge the trunk"
  [ "$(tip)" = "$before" ] || fail "a refused trunk move must leave the trunk where it was"
  out=$(plain_git -C "$PROJ" update-ref refs/heads/main "$lone" 2>&1) && fail "a hand move of main must be refused by the home guard"
  assert_contains "$out" "not on the trunk" "the home guard must judge main"
  lane chain good; c=$(git -C "$PROJ" rev-parse fm/chain)
  out=$(trunk land chain 2>&1) || fail "a landing must pass through both guards: $out"
  [ "$(tip)" = "$c" ] || fail "the landing must move the trunk"
  [ "$(cat "$hook" "$hook.chained" | git hash-object --stdin)" = "$both" ] || fail "the landing's own guard check must change neither hook"
  "$W/root/bin/jg-home-guard.sh" uninstall "$PROJ" >/dev/null || fail "uninstall must pass"
  [ "$(cat "$hook")" = "$trunk_hook" ] && [ ! -e "$hook.chained" ] || fail "uninstall must give the trunk guard its hook file back"
  pass 'the home guard chains the trunk guard: both still refuse, reruns and a landing change nothing, uninstall restores it'
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
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$c" ] || fail "the landing's own gate must move the green pin to the landed commit"
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
  lane two a; commit_in "$W/lanes/two" work.txt b "ticket two again"; prove two
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
  old=$(tip)
  plain_git -C "$PROJ" branch -f trunk "$(git -C "$PROJ" rev-parse trunk~1)" 2>/dev/null && fail "a hand write to the trunk must be refused by the hook"
  JG_TRUNK_WRITER=1 plain_git -C "$PROJ" branch -f trunk "$(git -C "$PROJ" rev-parse trunk~1)" 2>/dev/null && fail "even the lander's own writer must not rewind the trunk"
  JG_TRUNK_WRITER=1 plain_git -C "$PROJ" branch -D trunk 2>/dev/null && fail "a trunk must never be deleted"
  [ "$(tip)" = "$old" ] || fail "a refused write must leave the trunk where it was"
  printf '%s\n' "$(git -C "$PROJ" rev-parse fm/t2)" > "$HOME_D/state/trunk-tip-proj"
  refused 'a trunk whose record does not match' t2 'something else moved it'
  printf '%s\n' "$old" > "$HOME_D/state/trunk-tip-proj"
  pass 'every unsafe landing refuses and leaves the trunk where it was'
}

test_a_lane_with_a_ticket_lands_only_with_its_trailer() {
  local out amend
  world trailer
  lane tk a; printf 'ticket=jg-x.1\n' >> "$HOME_D/state/tk.meta"
  lane rb c rb.txt; printf 'ticket=jg-x.3\n' >> "$HOME_D/state/rb.meta"
  git -C "$W/lanes/rb" -c user.name=t -c user.email=t@example.invalid commit -q --amend -m "rb work" --trailer "Ticket: jg-x.3"; prove rb
  refused 'a ticket lane with no trailer' tk 'Ticket: jg-x.1'
  assert_contains "$(trunk land tk 2>&1)" 'git commit --amend --no-edit --trailer "Ticket: jg-x.1"' 'the refusal must print the fix command'
  amend=$(git -C "$W/lanes/tk" -c user.name=t -c user.email=t@example.invalid commit -q --amend --no-edit --trailer "Ticket: jg-x.2" 2>&1) || fail "fixture amend: $amend"
  prove tk; refused 'a trailer naming another ticket' tk 'Ticket: jg-x.1'
  git -C "$W/lanes/tk" -c user.name=t -c user.email=t@example.invalid commit -q --amend -m "work done" --trailer "Ticket: jg-x.1"; prove tk
  lane other b other.txt
  trunk land tk >/dev/null 2>&1 || fail "a lane with its trailer must land"
  out=$(trunk land other 2>&1) || fail "a lane with no ticket= keeps the task-id text rule: $out"
  git -C "$PROJ" log -1 --format=%B trunk~1 | git interpret-trailers --parse | grep -Fxq 'Ticket: jg-x.1' || fail "the landed commit must keep its trailer"
  git -C "$PROJ" merge-base --is-ancestor trunk fm/rb && fail "fixture: rb must be based on an old tip"
  trunk land rb >/dev/null 2>&1 || fail "a stale lane with its trailer must land after the lander's rebase"
  git -C "$PROJ" log -1 --format=%B trunk | git interpret-trailers --parse | grep -Fxq 'Ticket: jg-x.3' || fail "the rebased commit must keep its trailer"
  lane noref2 d; git -C "$W/lanes/noref2" -c user.name=t -c user.email=t@example.invalid commit -q --amend -m "AB-12 work"; prove noref2
  refused 'a KEY-n commit in a home with no ticket-key file' noref2 'ticket reference'
  printf 'AB\n' > "$HOME_D/config/ticket-prefix"
  lane keyed e; git -C "$W/lanes/keyed" -c user.name=t -c user.email=t@example.invalid commit -q --amend -m "AB-12 work"; prove keyed
  out=$(trunk land keyed 2>&1) || fail "a KEY-n commit must land in a home that has a ticket-key file: $out"
  pass 'a ticket lane needs its Ticket trailer; a lane with none keeps the text rule; KEY-n needs a key file'
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

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_red_found_after_the_landing_pins_the_home_behind_it() {
  local first c out
  world smoke; rig
  # A charged red: s1's test fails at s1 and the commit before it passes, so a hand-run verify charges s1.
  first=$(tip); lane s1 'echo "not ok - s1 breaks the suite" >&2; exit 1' t/s1.test.sh; c=$(git -C "$PROJ" rev-parse fm/s1)
  printf 'gate-full=true\ngate-verify=bash %s/rig.sh --all\n' "$W" >> "$HOME_D/config/trunk-policy"
  out=$(trunk land s1 2>&1) || fail "a landing must pass the fast check: $out"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$c" ] || fail "the landing's gate must move the green pin"
  out=$(trunk verify "$PROJ" "$c" 2>&1) && fail "verify must fail on a commit the whole suite rejects"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$first" ] || fail "a red verify must take the green pin back below the commit: $out"
  trunk word live "$PROJ" "go live" >/dev/null || fail "the captain's word must record"
  out=$(trunk live "$PROJ" 2>&1) || fail "live must work with his word: $out"
  assert_contains "$(cat "$HOME_D/data/trunk-live.tsv")" "pinned-behind" "the live record must say the home is pinned behind"
  [ "$(tail -1 "$W/live-moves")" = "$first" ] || fail "the home must stay on the last green commit"
  pass 'a red found after the landing takes the green pin back and pins the home behind it'
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
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] || fail "every landing must move the green pin to its commit"
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
  out=$(trunk release "$PROJ" 2>&1) || fail "a published release must allow its proof to be retried: $out"
  assert_contains "$out" 'resuming its proof' 'a retry must name its proof stage'
  [ "$(grep -c 'pr create' "$W/gh-calls")" = 1 ] || fail "a proof retry must not open another PR"
  lane r3 three; trunk land r3 >/dev/null 2>&1 || fail "r3 must land"
  trunk word release "$PROJ" "ship it again" >/dev/null 2>&1
  out=$(trunk release "$PROJ" 2>&1) || fail "a later batch must release: $out"
  [ "$(grep -c 'pr create' "$W/gh-calls")" = 1 ] || fail "a release while the PR is open must open no second PR"
  [ "$(git --git-dir="$W/origin.git" rev-parse refs/heads/trunk)" = "$(tip)" ] || fail "the open PR must carry the new commits"
  pass 'the release is one PR from the trunk itself, on his word, with no release branch'
}

# T5b A release carries the last green commit, not the tip (fric-release-last-green): every landing moves the pin, so the tip is
# ahead of it only while a red found after a landing holds the pin below it. The word binds to the same commit.
test_a_release_carries_the_last_green_commit_while_the_tip_is_ahead() {
  local out green tipc
  world rel-green
  lane g1 one; lane g2 two
  trunk land g1 >/dev/null 2>&1 || fail "g1 must land"
  green=$(tip); [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$green" ] || fail "the landing must move the green pin to g1"
  relane g2 two; trunk land g2 >/dev/null 2>&1 || fail "g2 must land"
  tipc=$(tip); [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$tipc" ] || fail "the landing must move the green pin to g2"
  printf '%s\n' "$green" > "$HOME_D/state/trunk-green-proj"  # fixture: a red found after g2 landed took the pin back to g1
  trunk word release "$PROJ" "ship the green one" >/dev/null 2>&1 || fail "the word must record while the tip is ahead of green"
  [ "$(cut -f1 "$HOME_D/state/trunk-word-release-proj")" = "$green" ] || fail "the release word must name the green commit, not the tip"
  out=$(trunk release "$PROJ" 2>&1) || fail "a tip ahead of the green pin must release the green commit: $out"
  [ "$(git --git-dir="$W/origin.git" rev-parse refs/heads/trunk)" = "$green" ] || fail "origin trunk must hold the last green commit, not the tip"
  [ "$(tip)" = "$tipc" ] || fail "a release must leave the local trunk where it is"
  [ "$(cat "$HOME_D/state/trunk-released-proj")" = "$green" ] || fail "the released mark must be the green commit"
  assert_contains "$out" 'released 1 commits' 'the release must count only the commits up to the green one'
  out=$(trunk release "$PROJ" 2>&1) || fail "the already-published green commit must allow proof retry: $out"
  assert_contains "$out" 'resuming its proof' 'the published green commit retries its proof'
  [ "$(git --git-dir="$W/origin.git" rev-parse refs/heads/trunk)" = "$green" ] || fail "the commit after the pin must wait for its own green"
  trunk verify "$PROJ" >/dev/null 2>&1 || fail "verify must pass at g2"
  trunk word release "$PROJ" "ship the next one" >/dev/null 2>&1 || fail "the word must record at the new green"
  trunk release "$PROJ" >/dev/null 2>&1 || fail "the next green commit must release"
  [ "$(git --git-dir="$W/origin.git" rev-parse refs/heads/trunk)" = "$tipc" ] || fail "a tip that is green must be pushed as before"
  rm -f "$HOME_D/state/trunk-green-proj"
  out=$(trunk word release "$PROJ" "no green yet" 2>&1) && fail "a word must refuse while no green commit is recorded"
  assert_contains "$out" 'no green commit of trunk is recorded yet' 'no recorded green must say so'
  out=$(trunk release "$PROJ" 2>&1) && fail "a release must refuse while no green commit is recorded"
  assert_contains "$out" 'no green commit of trunk is recorded yet' 'a release with no green commit must say so'
  pass 'a release carries the last green commit while the tip is ahead, a green tip is pushed as before, and no recorded green refuses'
}

test_a_red_ci_pins_the_home_back_to_the_last_green_commit() {
  local c1 c2 out
  world ci
  lane c1 one; c1=$(git -C "$PROJ" rev-parse fm/c1); trunk land c1 >/dev/null 2>&1 || fail "c1 must land"
  trunk word live "$PROJ" "go" >/dev/null 2>&1; trunk live "$PROJ" >/dev/null 2>&1 || fail "c1 must go live"
  lane c2 two; c2=$(git -C "$PROJ" rev-parse fm/c2); trunk land c2 >/dev/null 2>&1 || fail "c2 must land"
  trunk word live "$PROJ" "go" >/dev/null 2>&1; trunk live "$PROJ" >/dev/null 2>&1 || fail "c2 must go live"
  [ "$(tail -1 "$W/live-moves")" = "$c2" ] || fail "fixture: the home must be at c2"
  out=$(trunk ci "$PROJ" "$c2" red 2>&1) || fail "a red CI must record and pin back: $out"
  [ "$(tail -1 "$W/live-moves")" = "$c1" ] || fail "a red CI must move the home back to the last green live commit"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$c1" ] || fail "the green pin must be the last green commit"
  lane c3 three; out=$(trunk land c3 2>&1) || fail "a red CI never stops a landing: $out"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$c1" ] || fail "a landing above the CI-red commit leaves the green pin on the last green commit"
  trunk word live "$PROJ" "go" >/dev/null 2>&1; trunk live "$PROJ" >/dev/null 2>&1 || fail "live after a pin-back must work with his word"
  [ "$(tail -1 "$W/live-moves")" = "$c1" ] || fail "the home must stay pinned on the last green commit"
  # A landed commit that reverts the CI-red one clears the hold: its landing moves the pin again.
  lane c4 one work.txt "reverts: $c2"; out=$(trunk land c4 2>&1) || fail "the revert lane must land: $out"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] || fail "a landing above a reverted red moves the green pin to it"
  pass 'a red CI pins the green pin and the home back to the last green commit, landings go on, and the pin waits until the red is reverted'
}

test_the_trunk_stays_safe_until_its_release_lands_then_the_next_version_is_cut() {
  local out old
  world roll
  lane v1 one; trunk land v1 >/dev/null 2>&1 || fail "v1 must land"
  trunk word release "$PROJ" "ship it" >/dev/null 2>&1
  trunk release "$PROJ" >/dev/null 2>&1 || fail "the release must open"
  old=$(tip)
  out=$(trunk rollover "$PROJ" 2>&1) && fail "an open release must not roll the trunk over"
  assert_contains "$out" "rollover skipped" "an open release must say what was skipped"
  assert_contains "$out" "not merged" "an open release must say why nothing moved"
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
  assert_contains "$out" "already rolled over" "a repeated rollover must say why it was skipped"
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
  trunk word release "$PROJ" "ship it" >/dev/null 2>&1; trunk release "$PROJ" >/dev/null 2>&1 || fail "release must open"
  old=$(tip); wt="$W/oldwt"
  git -C "$PROJ" worktree add -q "$wt" trunk; printf 'scratch\n' > "$wt/unsaved.txt"
  printf 'merged\n' > "$W/pr-state"; git -C "$PROJ" push -q origin "$old:refs/heads/main"
  out=$(trunk rollover "$PROJ" 2>&1) || fail "the merged release must roll over: $out"
  assert_contains "$out" "kept worktree $wt: it holds uncommitted work" "a worktree with unlanded work must keep the old trunk"
  # A commit that reaches the old trunk after the cut was not in the rollover's replay (tests/jg-trunk-rollover.test.sh owns that).
  JG_TRUNK_WRITER=1 commit_in "$wt" hot.txt hotfix "ticket hx"; hot=$(git -C "$wt" rev-parse HEAD)
  out=$(trunk retire "$PROJ" 2>&1) || fail "retire must not fail: $out"
  assert_contains "$out" "kept trunk: hotfix not carried into trunk-v2: " "a hotfix not carried must keep the old trunk and be listed"
  assert_contains "$out" "ticket hx" "the uncarried hotfix must be named"
  git -C "$PROJ" rev-parse --verify -q refs/heads/trunk >/dev/null || fail "an old trunk with an uncarried hotfix must not be deleted"
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

# shellcheck disable=SC2016 # the gate bodies are written out verbatim and expand when the gate runs them
test_a_refusal_reaches_the_lanes_worker_and_never_sits_silent() {
  local out gone h f real_backlog=0
  world reach
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  # An incomplete proof: the worker is steered with the refusal text, and the done itself names what to run.
  lane r1 one; rm "$HOME_D/data/r1/merge-card.json"
  out=$(done_gate r1) && fail "a done with no merge-card evidence must be refused: $out"
  assert_contains "$out" "merge-card check r1" "the done names the command to run"
  printf '# the done is refused and names what to run: %s\n' "$out"
  sweep >/dev/null
  [ "$(sends r1)" = 1 ] || fail "the refused lane's worker must be steered once, got $(sends r1)"
  assert_contains "$(grep '^r1	' "$W/send-calls")" "proof inputs are incomplete" "the steer carries the refusal text"
  assert_contains "$(grep '^r1	' "$W/send-calls")" "merge-card check r1" "the steer names what to run"
  printf '# the lane worker is steered: %s\n' "$(grep '^r1	' "$W/send-calls" | head -n 1)"
  sweep >/dev/null; [ "$(sends r1)" = 1 ] || fail "the same refusal must not steer again before it is due"
  # Re-rung while the head is unchanged, unless the worker still has an unread steer (the inbox's own ladder rings that one).
  rf=$(ls "$HOME_D"/data/jg-trunk-landing/r1.*.refusal); sed -i "s/^\([0-9]*\) \([0-9]*\) [0-9]* /\1 \2 $(( $(date +%s) - 700 )) /" "$rf"
  mkdir -p "$HOME_D/state/r1.inbox"; : > "$HOME_D/state/r1.inbox/001.msg"
  sweep >/dev/null; [ "$(sends r1)" = 1 ] || fail "a worker with an unread steer is not steered again"
  rm "$HOME_D/state/r1.inbox/001.msg"
  sweep >/dev/null; [ "$(sends r1)" = 2 ] || fail "an unchanged head is steered again when the last steer is due: $(sends r1)"
  # Nobody acted for ten minutes: one alert names the lane and the refusal.
  out=$(sweep); [[ $out != *ALERT* ]] || fail "no alert before ten minutes: $out"
  sed -i "s/^[0-9]* /$(( $(date +%s) - 700 )) /" "$rf"
  out=$(sweep); assert_contains "$out" "ALERT: r1 has sat refused for over 10 minutes" "the alert names the lane"
  assert_contains "$out" "no approved merge-card evidence" "the alert names the refusal"
  printf '# after ten silent minutes: %s\n' "$out"
  out=$(sweep); [[ $out != *ALERT* ]] || fail "the alert is raised once: $out"
  # A final refusal (a red gate) tells the ticket and steers the worker once.
  if [ -n "${JG_BEADS_TEST_BD:-}" ] && [ -n "${JG_BEADS_TEST_DOLT:-}" ]; then
    jg_test_beads_home "$HOME_D"
    cp "$ROOT/bin/jg-backlog.sh" "$HOME_D/bin/jg-backlog.sh"
    cp "$ROOT/toolchain.versions" "$HOME_D/toolchain.versions"
    jg_test_backlog "$HOME_D" add jg-r2 '[feature] refusal fixture' --kind ship --repo proj --body 'Prove a final refusal reaches its owner.' >/dev/null || fail 'create jg-r2 ticket'
    jg_test_backlog "$HOME_D" add jg-r5 '[feature] retry fixture' --kind ship --repo proj --body 'Prove exhausted retries reach their owner.' >/dev/null || fail 'create jg-r5 ticket'
    real_backlog=1
  else
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/backlog-calls"\n' "$W" > "$HOME_D/bin/jg-backlog.sh"
    chmod +x "$HOME_D/bin/jg-backlog.sh"
    printf '# real ticket assertions skipped: no pinned Beads tools\n'
  fi
  cp "$HOME_D/bin/jg-send.sh" "$W/send-stub"
  cp "$ROOT/bin/jg-send.sh" "$HOME_D/bin/jg-send.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/tmux"; chmod +x "$W/fakebin/tmux"
  lane jg-r2 BAD
  printf 'kind=ship\nharness=codex\nwindow=sess:jg-jg-r2\n' >> "$HOME_D/state/jg-r2.meta"
  sweep >/dev/null; sweep >/dev/null
  assert_contains "$(cat "$HOME_D/state/jg-r2.inbox/001.msg" 2>/dev/null)" "gate 'full' failed" "a final refusal reaches its worker"
  if [ "$real_backlog" = 1 ]; then
    assert_contains "$(jg_test_backlog "$HOME_D" show jg-r2 --full)" "gate 'full' failed" "the final refusal reaches its ticket"
  else assert_contains "$(cat "$W/backlog-calls" 2>/dev/null)" "update jg-r2 --body-file" "the final refusal reaches its ticket"; fi
  [ "$(find "$HOME_D/state/jg-r2.inbox" -maxdepth 1 -name '*.msg' | wc -l)" = 1 ] || fail "a final refusal sends one steer"
  assert_not_contains "$(cat "$HOME_D"/data/jg-trunk-landing/jg-r2.*.log)" "unbound variable" "the real lander completes its refusal"
  assert_contains "$(JG_HOME="$HOME_D" "$HOME_D/bin/jg-machine.sh" show task jg-r2)" "rework" "the refused lane is in rework"
  cp "$W/send-stub" "$HOME_D/bin/jg-send.sh"
  # The lane changes its head: the old refusal is history and the new head is judged on its own.
  gone=$(git -C "$PROJ" rev-parse fm/r1); relane r1 two; ready r1
  sweep >/dev/null; sweep >/dev/null
  [ "$(sends r1)" = 2 ] || fail "a lane with a new head is not steered about its old head: $(grep '^r1	' "$W/send-calls" | cut -c1-80)"
  [ "$(git -C "$PROJ" rev-parse fm/r1)" != "$gone" ] || fail "the lane moved to a new head"
  [ "$(tip)" = "$(git -C "$PROJ" rev-parse fm/r1)" ] || fail "the new, proved head lands"
  # A refusal recorded for a head the lane no longer has steers nobody.
  lane r3 three; printf 'final REFUSED: an old refusal\n' > "$HOME_D/data/jg-trunk-landing/r3.0000000000000000000000000000000000000000.state"
  sweep >/dev/null; sweep >/dev/null
  [ "$(sends r3)" = 0 ] || fail "a stale-head refusal must steer nobody: $(grep "^r3	" "$W/send-calls" | cut -c1-300)"
  # A refusal that only needs time is not the worker's to fix.
  lane r4 four; : > "$HOME_D/state/.afk"; sweep >/dev/null; sweep >/dev/null; rm "$HOME_D/state/.afk"
  [ "$(sends r4)" = 0 ] || fail "a wait for time (away mode) must not steer the worker"
  # An infrastructure failure becomes final only after three attempts and then reaches the owner once.
  sweep >/dev/null; sweep >/dev/null
  printf 'gate-full=echo "cat: write error: Disk quota exceeded"; exit 1\n' >> "$HOME_D/config/trunk-policy"
  cp "$ROOT/bin/jg-send.sh" "$HOME_D/bin/jg-send.sh"
  lane jg-r5 five jg-r5.txt; printf 'kind=ship\nharness=codex\nwindow=sess:jg-jg-r5\n' >> "$HOME_D/state/jg-r5.meta"
  h=$(git -C "$PROJ" rev-parse fm/jg-r5); f=$HOME_D/data/jg-trunk-landing/jg-r5.$h.state
  for n in 1 2 3; do
    sweep >/dev/null
    for _ in $(seq 1 600); do
      if ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && ! compgen -G "$HOME_D/state/.trunk-run-*.lock" >/dev/null; then break; fi
      sleep 0.2
    done
    [ -f "$f" ] || fail "retry $n has no verdict"
    if [ "$n" -lt 3 ]; then [ ! -d "$HOME_D/state/jg-r5.inbox" ] || fail "retry $n must not steer"; fi
    touch -d '3 minutes ago' "$f"
  done
  sweep >/dev/null
  [ "$(find "$HOME_D/state/jg-r5.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l)" = 1 ] || fail "the final retry verdict must send one steer: $(cat "$f")"
  if [ "$real_backlog" = 1 ]; then
    assert_contains "$(jg_test_backlog "$HOME_D" show jg-r5 --full)" "gave up after 3 tries" "the final retry verdict reaches its ticket"
  else assert_contains "$(cat "$W/backlog-calls")" "update jg-r5 --body-file" "the final retry verdict reaches its ticket"; fi
  assert_contains "$(JG_HOME="$HOME_D" "$HOME_D/bin/jg-machine.sh" show task jg-r5)" "rework" "the exhausted lane is in rework"
  pass 'a refusal the worker fixes reaches it by steer, repeats until the head changes, alerts after ten silent minutes, and never steers a stale head or a wait'
}

test_l3_environment_wait_is_not_retried_in_batches() {
  local h n
  world l3-batch
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  lane b1 good b1.txt; lane b2 good b2.txt
  printf 'gate-full=echo attempt >> "%s/calls"; echo ENV: missing-fixture; exit 1\n' "$W" >> "$HOME_D/config/trunk-policy"
  sweep >/dev/null; sleep 1
  h=$(git -C "$PROJ" rev-parse fm/b1)
  [ -f "$W/calls" ] || fail "batch gate must run"
  sweep >/dev/null; sleep 1; sweep >/dev/null; sleep 1
  n=$(wc -l < "$W/calls")
  sweep >/dev/null; sleep 1; sweep >/dev/null; sleep 1
  [ "$(wc -l < "$W/calls")" -eq "$n" ] || fail "unchanged environment must not rerun a batch gate"
  pass 'an unchanged batch environment refusal does not rerun the gate'
}

test_l3_environment_facts_retirement_and_self_init() {
  local n h old new out other
  world l3-facts
  lane facts good
  mkdir -p "$W/hooks"; git -C "$PROJ" config core.hooksPath "$W/hooks"
  printf 'gate-full=test -f "%s/hooks/ready" || { echo ENV: fixture-unavailable; exit 1; }\n' "$W" >> "$HOME_D/config/trunk-policy"
  out=$(trunk land facts 2>&1) && fail "missing environment fact must refuse"
  assert_contains "$out" "refusal-class facts: env-wait" "environment refusal must be typed"
  n=$(find "$HOME_D/data/jg-trunk-landing" -name 'facts.*.attempt-*' | wc -l)
  for _ in 1 2 3; do trunk land facts >/dev/null 2>&1 && fail "unchanged environment must remain refused"; done
  [ "$(find "$HOME_D/data/jg-trunk-landing" -name 'facts.*.attempt-*' | wc -l)" = "$n" ] || fail "unchanged context retried"
  : > "$W/hooks/ready"
  trunk land facts >/dev/null 2>&1 || fail "changed hook directory must admit a new attempt"
  [ "$(find "$HOME_D/data/jg-trunk-landing" -name 'facts.*.attempt-*' | wc -l)" -eq $((n + 1)) ] || fail "changed facts must admit exactly one attempt"
  [ -n "$(find "$HOME_D/data/jg-trunk-landing/retired" -name 'facts.*.state' -print -quit)" ] || fail "the old admission key must retire"

  world l3-retire
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  mkdir -p "$HOME_D/data/jg-trunk-landing"
  lane stale good; old=$(git -C "$PROJ" rev-parse fm/stale)
  printf 'final REFUSED: trunk moved\n' > "$HOME_D/data/jg-trunk-landing/stale.$old.state"
  relane stale better; new=$(git -C "$PROJ" rev-parse fm/stale)
  [ "$old" != "$new" ] || fail "fixture must change head"
  sweep >/dev/null
  [ ! -e "$HOME_D/data/jg-trunk-landing/stale.$old.state" ] || fail "superseded final must leave active records"
  [ -f "$HOME_D/data/jg-trunk-landing/retired/stale.$old.state" ] || fail "superseded final must be retained in retired"

  world l3-init
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  other="$HOME_D/projects/other"; jg_git_init_commit "$other"
  printf '%s\n' '- other [local-trunk] - fixture' >> "$HOME_D/data/projects.md"
  out=$(sweep)
  [ -s "$HOME_D/state/trunk-tip-other" ] || fail "registered project must self-init: $out"
  [ "$(cat "$HOME_D/state/trunk-tip-other")" = "$(git -C "$other" rev-parse HEAD)" ] || fail "self-init must use project HEAD"
  pass 'changed hook facts admit once, superseded final retires, and registered projects self-init'
}

test_recover_diverged_trunk() {
  local base pin actual out merge third i
  world recovery
  git -C "$PROJ" config user.name fixture
  git -C "$PROJ" config user.email fixture@example.invalid
  base=$(tip)
  for i in 1 2 3 4 5 6 7 8; do lane "p$i" "$i" "p$i.txt"; trunk land "p$i" >/dev/null 2>&1 || fail "pin lane $i"; done
  pin=$(tip)
  git -C "$PROJ" worktree add -q --detach "$W/actual-wt" "$base"
  commit_in "$W/actual-wt" actual.txt actual 'actual branch'
  actual=$(git -C "$W/actual-wt" rev-parse HEAD)
  plain_git -C "$PROJ" -c core.hooksPath=/dev/null update-ref refs/heads/trunk "$actual" "$pin"
  out=$(trunk land p1 2>&1) && fail 'ordinary landing must refuse divergence'
  out=$(trunk recover "$PROJ" 2>&1) || fail "report: $out"
  assert_contains "$out" "$pin" 'report pin'
  assert_contains "$out" "$actual" 'report actual'
  out=$(trunk recover "$PROJ" --prepare recovery 2>&1) || fail "prepare: $out"
  merge=$(git -C "$PROJ" rev-parse refs/heads/fm/recovery)
  [ "$(tip)" = "$actual" ] || fail 'prepare moves no trunk'
  jg_write_meta "$HOME_D/state/recovery.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/recovery"
  out=$(trunk recover "$PROJ" --land recovery 2>&1) && fail 'missing proof must refuse'
  prove recovery
  third=$(git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit-tree "$(git -C "$PROJ" rev-parse "$actual^{tree}")" -p "$actual" -m third)
  plain_git -C "$PROJ" -c core.hooksPath=/dev/null update-ref refs/heads/trunk "$third" "$actual"
  out=$(trunk recover "$PROJ" --land recovery 2>&1) && fail 'third ref must refuse'
  [ "$(tip)" = "$third" ] || fail 'third ref preserved'
  plain_git -C "$PROJ" -c core.hooksPath=/dev/null update-ref refs/heads/trunk "$actual" "$third"
  trunk recover "$PROJ" --land recovery >/dev/null || fail 'proved merge must land'
  [ "$(tip)" = "$merge" ] || fail 'exact merge landed'
  git -C "$PROJ" merge-base --is-ancestor "$pin" "$merge" || fail 'pin retained'
  git -C "$PROJ" merge-base --is-ancestor "$actual" "$merge" || fail 'actual retained'
  lane next next next.txt; trunk land next >/dev/null 2>&1 || fail 'ordinary landing resumes after recovery'
  pass 'divergent trunk recovers only the exact proved merge'
}

test_recover_diverged_trunk
test_l3_environment_wait_is_not_retried_in_batches
test_l3_environment_facts_retirement_and_self_init
test_configured_hooks_and_the_launch_overlay_preserve_trunk_protection
test_a_home_with_other_shas_is_contained_only_when_the_trunk_took_its_changes
test_admission_is_shared_by_manual_and_automatic_requests
test_a_repaired_hook_overlay_admits_exactly_one_fresh_attempt
test_legacy_mode_stays_interoperable
test_the_home_guard_chains_the_trunk_guard
test_a_good_lane_lands_but_goes_live_only_on_his_word
test_every_unsafe_landing_refuses
test_a_lane_with_a_ticket_lands_only_with_its_trailer
test_a_seam_is_the_only_place_behaviour_changes
test_a_red_found_after_the_landing_pins_the_home_behind_it
test_the_release_is_one_pr_from_the_trunk_on_his_word
test_a_release_carries_the_last_green_commit_while_the_tip_is_ahead
test_a_red_ci_pins_the_home_back_to_the_last_green_commit
test_the_trunk_stays_safe_until_its_release_lands_then_the_next_version_is_cut
test_the_old_trunk_is_cleaned_up_unforced_and_only_when_its_work_is_carried
test_a_refusal_reaches_the_lanes_worker_and_never_sits_silent
test_adopt_tip_ends_a_moved_trunk_with_a_record_and_loses_no_landed_commit
test_adopt_tip_takes_a_forward_move_and_refuses_an_unexplained_one_a_worker_and_any_flag
test_landing_adopts_forward_and_refuses_rewind
printf 'jg-trunk: ok\n'
