#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh adopt-tip and the landing check's adoption of a moved trunk (split out of tests/jg-trunk.test.sh):
# T-adopt a trunk the lander did not leave is ended with a record and no landed commit lost; a forward move is adopted by the landing check, a rewind is refused.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# moved_world <name>: byokit's shape. Lanes l1 and l2 landed; then the trunk branch is set by hand (no hook, as on the real home) to a
# commit M of origin/main that lacks them. Lane c holds one commit on M whose tree is the merge of the old record and M.
moved_world() {
  local base
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
  [ "$(grep -c "trunk-moved-proj-${OLD:0:12}-${M:0:12}" "$HOME_D/state/.wake-queue")" = 1 ] || fail "one drift alert, keyed by record and branch, however many refusals: $(cat "$HOME_D/state/.wake-queue" 2>&1)"
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

test_adopt_tip_ends_a_moved_trunk_with_a_record_and_loses_no_landed_commit
test_adopt_tip_takes_a_forward_move_and_refuses_an_unexplained_one_a_worker_and_any_flag
test_landing_adopts_forward_and_refuses_rewind
printf 'jg-trunk-adopt: ok\n'
