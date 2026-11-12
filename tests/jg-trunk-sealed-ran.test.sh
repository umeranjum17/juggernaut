#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh: a sealed run says what it ran, and the lander counts it only when that covers the landing's tests.
# Through tests/jg-trunk-fixture.sh it runs `jg-trunk.sh land` (sealed_run_covers, landing_selection) over a project that carries a
# changed-tests selector (bin/jg-test-run.sh --changed --list), and stands in for the other helpers the fixture stubs.
#
# T1 A lane whose sealed run ran one journey and not its changed tests is not counted: the landing runs the tests (gate=full).
# T2 A lane whose sealed run wrote the list of the changed scripts it ran, all passed, is counted: the landing runs the lint alone (gate=sealed-run).
# T3 A run whose list names the script with a failing exit, or whose list file no longer matches the hash the record holds, is not counted.
# T4 A project with no changed-tests selector is judged by the tree alone, as before.
# T5 A sealed run counts for a rebased commit that is the same change (no test runs at the landing, the landing time is printed); a rebase that
#    changed the patch goes back to proving (gate=full); a conflict goes back to building (refused). The green pin is not moved by a landing.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# A stand-in selector with the contract the lander reads: --changed --base <ref> --list prints the changed test scripts, one per line.
# shellcheck disable=SC2016 # the script body is written out verbatim
selector() {
  git -C "$PROJ" worktree add -q -b seed-sel "$W/seed-sel" trunk
  commit_in "$W/seed-sel" bin/jg-test-run.sh '#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" != --base ] || { base=$2; shift; }; shift; done
git diff --name-only "$base" HEAD -- "tests/*.test.sh"' "seed selector"
  chmod +x "$W/seed-sel/bin/jg-test-run.sh"; git -C "$W/seed-sel" add bin/jg-test-run.sh
  git -C "$W/seed-sel" -c user.name=t -c user.email=t@example.invalid commit -q --amend --no-edit
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/seed-sel" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
  git -C "$PROJ" worktree remove --force "$W/seed-sel"
  printf 'gate-full=echo ran >> %s/gate-runs\ngate-lint=true\n' "$W" > "$HOME_D/config/trunk-policy"
}

# seal_with <id> <list json or -> [<files form: plain|hash>]: the lane's sealed run, with the list a changed-tests run wrote into its folder.
seal_with() {
  local id=$1 h d="$HOME_D/data/$1" run files
  h=$(git -C "$PROJ" rev-parse "fm/$id"); run="20261111T000000Z-${h:0:8}-ab"; mkdir -p "$d/$run"
  printf 'ok\n' > "$d/run.log"; files='"run.log"'
  if [ "$2" != - ]; then
    printf '%s\n' "$2" > "$d/$run/changed-tests.json"
    if [ "${3:-plain}" = hash ]; then files="$files,{\"path\":\"$run/changed-tests.json\",\"sha256\":\"$(sha256sum "$d/$run/changed-tests.json" | cut -d' ' -f1)\",\"bytes\":1}"
    else files="$files,\"$run/changed-tests.json\""; fi
  fi
  printf '{"schema":1,"run_id":"%s","commit":"%s","exit":0,"dirty":false,"started_at":"2026-11-11T00:00:00Z","files":[%s]}\n' "$run" "$h" "$files" > "$d/.done-done/runs/run-$h.json"
}
ran() { printf '{"scripts":[{"path":"%s","exit":%s}]}' "$1" "${2:-0}"; }

# A lane that changes tests/<name>.test.sh on the tip, with a PASS receipt; the caller seals it as it likes.
test_a_sealed_run_counts_only_when_it_says_it_ran_the_changed_tests() {
  local out
  world ran; JG_TRUNK_SEALED_REUSE=1; selector

  lane a1 'exit 0' tests/a.test.sh; seal_with a1 "$(ran journeys/other.sh)"
  out=$(trunk land a1 2>&1) || fail "a1 must land: $out"
  assert_contains "$out" "gate=full" "a run that ran one journey and not the changed tests is not counted"
  [ -e "$W/gate-runs" ] || fail "the tests must run at the landing for a run that did not list them"
  rm -f "$W/gate-runs"

  lane a2 'exit 0' tests/b.test.sh; seal_with a2 -
  out=$(trunk land a2 2>&1) || fail "a2 must land: $out"
  assert_contains "$out" "gate=full" "a run with no list says nothing of what it ran"
  [ -e "$W/gate-runs" ] || fail "the tests must run for a run with no list"
  rm -f "$W/gate-runs"

  lane a3 'exit 0' tests/c.test.sh; seal_with a3 "$(ran tests/c.test.sh)"
  out=$(trunk land a3 2>&1) || fail "a3 must land: $out"
  assert_contains "$out" "gate=sealed-run" "a run that lists the selection is counted"
  [ ! -e "$W/gate-runs" ] || fail "the tests must not run again for a run that listed them"

  lane a4 'exit 1' tests/d.test.sh; seal_with a4 "$(ran tests/d.test.sh 1)"
  out=$(trunk land a4 2>&1) || :
  [ -e "$W/gate-runs" ] || fail "a list that shows the changed test failing is not counted"
  rm -f "$W/gate-runs"

  lane a5 'exit 0' tests/e.test.sh; seal_with a5 "$(ran tests/e.test.sh)" hash
  printf '%s\n' "$(ran journeys/other.sh)" > "$HOME_D/data/a5/20261111T000000Z-$(git -C "$PROJ" rev-parse "fm/a5" | cut -c1-8)-ab/changed-tests.json"
  out=$(trunk land a5 2>&1) || fail "a5 must land: $out"
  assert_contains "$out" "gate=full" "a list changed after the run no longer matches the hash the record holds"
  rm -f "$W/gate-runs"

  lane a6 'exit 0' tests/f.test.sh; seal_with a6 "$(ran tests/f.test.sh)" hash
  out=$(trunk land a6 2>&1) || fail "a6 must land: $out"
  assert_contains "$out" "gate=sealed-run" "a list that matches its recorded hash is counted"
  pass 'a sealed run is counted only when its own list shows the landing'"'"'s changed tests ran and passed'
}

test_a_project_without_a_selector_is_judged_by_the_tree_alone() {
  local out
  world nosel; JG_TRUNK_SEALED_REUSE=1
  printf 'gate-full=echo ran >> %s/gate-runs\ngate-lint=true\n' "$W" > "$HOME_D/config/trunk-policy"
  lane n1 'exit 0' tests/a.test.sh
  out=$(trunk land n1 2>&1) || fail "n1 must land: $out"
  assert_contains "$out" "gate=sealed-run" "with no selector the sealed run at the tree stands"
  [ ! -e "$W/gate-runs" ] || fail "no tests run again"
  pass 'a project with no changed-tests selector keeps the tree rule'
}

# advance <file> <content>: the trunk moves under the lanes, as another landing would move it.
advance() {
  git -C "$PROJ" worktree add -q -b adv-$RANDOM "$W/adv" trunk
  commit_in "$W/adv" "$1" "$2" "advance $1"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/adv" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
  git -C "$PROJ" worktree remove --force "$W/adv"
}

test_a_rebase_with_the_same_change_lands_without_a_test() {
  local out pin
  world rebased; JG_TRUNK_SEALED_REUSE=1; selector
  advance tests/ctx.test.sh $'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10'
  pin=$(cat "$HOME_D/state/trunk-green-proj" 2>/dev/null || echo none)

  lane r1 'exit 0' tests/r.test.sh; seal_with r1 "$(ran tests/r.test.sh)"
  lane r2 $'l1\nl2\nl3\nl4\nl5\nl6\nl7\nL8\nl9\nl10' tests/ctx.test.sh; seal_with r2 "$(ran tests/ctx.test.sh)"
  lane r3 $'L1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10' tests/ctx.test.sh; seal_with r3 "$(ran tests/ctx.test.sh)"
  lane r4 'mine' conflict.txt; seal_with r4 -
  advance tests/other.test.sh 'exit 0'   # r1 moves onto a new tip with its patch unchanged
  advance tests/ctx.test.sh $'l1\nl2\nl3\nl4\nM5\nl6\nl7\nl8\nl9\nl10'  # r2's context line changes; r3's patch is untouched
  advance conflict.txt 'theirs'

  out=$(trunk land r1 2>&1) || fail "r1 must land: $out"
  assert_contains "$out" "gate=sealed-run" "a rebase with the same patch keeps the sealed run"
  assert_contains "$out" "s)" "the landing time is printed"
  [ ! -e "$W/gate-runs" ] || fail "no test runs at the landing of an unchanged patch"

  out=$(trunk land r2 2>&1) || fail "r2 must land: $out"
  assert_contains "$out" "gate=full" "a rebase that changed the patch goes back to proving"
  [ -e "$W/gate-runs" ] || fail "the tests must run for a patch that changed in the rebase"
  rm -f "$W/gate-runs"

  out=$(trunk land r3 2>&1) || fail "r3 must land: $out"
  assert_contains "$out" "gate=sealed-run" "a rebase of a patch far from the trunk's edit keeps the run"

  out=$(trunk land r4 2>&1) && fail "r4 conflicts and must not land: $out"
  assert_contains "$out" "conflicts" "a conflict goes back to building"

  [ "$(cat "$HOME_D/state/trunk-green-proj" 2>/dev/null || echo none)" = "$pin" ] || fail "a landing must not move the green pin"
  pass 'a sealed run follows a rebase with the same change, and only that'
}

test_a_sealed_run_counts_only_when_it_says_it_ran_the_changed_tests
test_a_rebase_with_the_same_change_lands_without_a_test
test_a_project_without_a_selector_is_judged_by_the_tree_alone
printf 'jg-trunk-sealed-ran: ok\n'
