#!/usr/bin/env bash
# Integration test for verify by milestone (slice H29h, core/trunk-verify/milestone.sh), through the real bin/jg-trunk.sh verify and the
# shared fixture tests/jg-trunk-fixture.sh: real git repositories and the real gate chain.
# M1 a milestone holds N commits, N set from the measured bad-commit share: 13 at 5%, so 30 landed lanes are judged in milestones of
#    13, 13 and 4, and the green pin moves to each top.
# M2 at a 24% share N is 2: six landed lanes are three milestones of 2.
# M3 the commits that landed within 15 minutes of a milestone's first commit are all it holds: lanes landed 20 minutes apart are
#    separate milestones even when N would allow more.
# M4 30 lanes with 2 bad ones in different milestones: a red milestone is split with both halves at once until each bad commit stands
#    alone, both are reverted by one verify, the pin stands on the last commit before the first bad one, the rounds stay within
#    2 x log2(N), and a second verify moves the pin to the tip.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# A gate that logs each run's start and end, then runs the stand-in test runner over the tree.
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
ms_gate() {
  cat > "$W/ms.sh" <<SH
#!/usr/bin/env bash
echo "s \$\$" >> $W/ms.log; sleep 0.3
bash $W/rig.sh --all; rc=\$?
echo "e \$\$" >> $W/ms.log; exit \$rc
SH
  printf 'gate-full=true\ngate-verify=bash %s/ms.sh\n' "$W" >> "$HOME_D/config/trunk-policy"
}
runs() { grep -c '^s ' "$W/ms.log" 2>/dev/null || echo 0; }

# seed_share <landed rows> <reverted rows>: the ledger of a home with that bad-commit share once the real landings are added (100 landings in all).
seed_share() {
  local i
  for i in $(seq 1 "$1"); do printf 'seed-%s\tproj\t%040d\t1\tfull\n' "$i" "$i" >> "$HOME_D/data/trunk-landings.tsv"; done
  for i in $(seq 1 "$2"); do printf 'revert-%s\tproj\t%040d\t1\treverts-x\n' "$i" "$i" >> "$HOME_D/data/trunk-landings.tsv"; done
}

# stack <name> <lanes> <bad indexes, space separated> <seeded landings> <seeded reverts>: lanes landed above the pin; a bad lane adds a failing test.
stack() {
  local i body
  world "$1"; rig; ms_gate; seed_share "$4" "$5"
  lane base 'exit 0' t/base.test.sh; trunk land base >/dev/null 2>&1 || fail "base must land"; tip > "$HOME_D/state/trunk-green-proj"
  for i in $(seq 1 "$2"); do
    body='exit 0'; case " $3 " in *" $i "*) body='echo "not ok - bad lane" >&2; exit 1' ;; esac
    GIT_COMMITTER_DATE="@$(( 1700000000 + ${GAP:-0} * i )) +0000" lane "l$i" "$body" "t/l$i.test.sh"
    trunk land "l$i" >/dev/null 2>&1 || fail "l$i must land"
    BAD_AT="${BAD_AT:-}"; case " $3 " in *" $i "*) BAD_AT="$BAD_AT $(tip)" ;; esac
  done
  : > "$W/ms.log"
}
nth() { git -C "$PROJ" rev-list --reverse "$(cat "$HOME_D/state/trunk-green-proj")..trunk" | sed -n "$1p"; }
reverted() { git -C "$PROJ" log --format=%B trunk | sed -n 's/^reverts: //p' | sort; }

test_milestones_hold_n_commits_set_from_the_bad_share() {
  local out
  stack share5 30 "" 69 5
  out=$(trunk verify "$PROJ" 2>&1) || fail "a green stack must verify: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^verify: milestone of 13 commits')" = 2 ] || fail "two milestones of 13 expected at a 5% share: $out"
  assert_contains "$out" "milestone of 4 commits" "the last milestone holds the rest"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] || fail "the pin must stand on the tip"
  [ "$(runs)" = 3 ] || fail "three milestones are three runs: $(runs)"
  pass 'milestones hold N commits (13 at a 5% bad share) and the pin moves to the tip'
}

test_a_high_bad_share_makes_small_milestones() {
  local out
  stack share24 6 "" 93 24
  out=$(trunk verify "$PROJ" 2>&1) || fail "a green stack must verify: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^verify: milestone of 2 commits')" = 3 ] || fail "three milestones of 2 expected at a 24% share: $out"
  pass 'a 24% bad share makes milestones of 2 commits'
}

test_a_milestone_holds_only_the_commits_of_its_window() {
  local out
  GAP=1200 stack window 4 "" 95 5
  out=$(trunk verify "$PROJ" 2>&1) || fail "a green stack must verify: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^verify: milestone of 1 commits')" = 4 ] || fail "lanes 20 minutes apart are one milestone each: $out"
  pass 'a milestone holds only the commits that landed within 15 minutes of its first'
}

test_two_bad_commits_in_different_milestones_are_each_found_and_reverted() {
  local out first want rounds
  stack bad2 30 "5 20" 69 5
  first=$(nth 4)
  want=$(printf '%s\n' "$BAD_AT" | tr ' ' '\n' | sed '/^$/d' | sort)
  out=$(trunk verify "$PROJ" 2>&1) && fail "a red stack must fail the verify: $out"
  [ "$(reverted)" = "$want" ] || fail "both bad commits must be reverted and no other: got $(reverted | tr '\n' ' ')"
  assert_contains "$out" "its two halves" "a red milestone is split in two halves that run at once"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$first" ] || fail "the pin must stand on the last commit before the first bad one"
  rounds=$(runs); [ "$rounds" -le $(( 3 + 2 * 2 * 4 )) ] || fail "two bad commits in 30 must cost few runs, ran $rounds"
  out=$(trunk verify "$PROJ" 2>&1) || fail "the second verify must pass on the reverted trunk: $out"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] || fail "the second verify must move the pin to the tip"
  pass "two bad commits of 30 are each reverted by one verify in $rounds gate runs, the pin stops below the first, then moves to the tip"
}

test_milestones_hold_n_commits_set_from_the_bad_share
test_a_high_bad_share_makes_small_milestones
test_a_milestone_holds_only_the_commits_of_its_window
test_two_bad_commits_in_different_milestones_are_each_found_and_reverted
if [ -n "${DONE_DONE_EVIDENCE_ROOT:-}" ]; then
  cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<'JSON'
{
  "target": {"version": "bin/jg-trunk.sh verify"},
  "start": "a trunk with landed lanes above the green pin, some of them adding a failing test",
  "steps": [
    "the verify cuts the lanes into milestones of N commits or 15 minutes, N from the measured bad-commit share",
    "a red milestone is split with both halves at once until each bad commit stands alone",
    "each bad commit is reverted and the green pin stands on the last commit before the first bad one"
  ],
  "result": "a green stack moves the pin to the tip milestone by milestone; two bad commits of 30 are both reverted by one verify"
}
JSON
fi
printf 'jg-trunk-verify-milestone: ok\n'
