#!/usr/bin/env bash
# Integration test for the proof a local-trunk lane keeps across a rebase (bin/jg-merge-gate-lib.sh's jg_dod_trunk_proof_gaps,
# which asks core/merge-card/merge-card same-change). Through tests/jg-trunk-fixture.sh it runs bin/jg-trunk.sh, reads
# bin/jg-dod-lib.sh and stands in for bin/jg-captain-hold.sh, bin/jg-send.sh, bin/jg-teardown.sh, bin/jg-fleet-ledger.sh and
# bin/jg-home-health.sh.
#
# T19 A proved lane rebased with no change keeps its proof: `jg-trunk.sh proof` prints no gap, the worker's done with its receipt
#    published again at the new head is accepted while the merge-card check and sealed run stay at the old head, and the lane lands.
# T20 A lane whose change differs after the rebase is refused and the refusal names it: the seed is lander-refusal-reaches-worker on
#    9 Nov, proved at bf4cac943 and rebased at 15:27:21Z to bd60a810e, which dropped one file's hunk and had to seal its run again.
#    A rebase that changes only a file's mode is another change too.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# rebase_lane <id>: the lane's one commit is rebased onto the trunk tip with git itself; nothing in it is edited.
rebase_lane() { git -C "$W/lanes/$1" -c user.name=t -c user.email=t@example.invalid rebase -q trunk || fail "the rebase of $1 must apply"; }

test_a_proved_lane_rebased_with_no_change_keeps_its_proof_and_lands() {
  local old new out rc=0
  world same; cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  lane s1 'the change' s1.txt; old=$(git -C "$PROJ" rev-parse fm/s1)
  # The trunk moves under the proved lane: another lane lands on another file.
  lane s0 'other work' s0.txt; trunk land s0 >/dev/null 2>&1 || fail "s0 must land"
  rebase_lane s1; new=$(git -C "$PROJ" rev-parse fm/s1)
  [ "$new" != "$old" ] || fail "the rebase must give the lane a new commit id"
  printf '# rebased with no change: %s -> %s\n' "${old:0:12}" "${new:0:12}"
  out=$(trunk proof s1 2>&1) || rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] || fail "a rebase with no change must keep the proof, got exit $rc: $out"
  # The worker publishes its receipt again at the new head (the done asks for that); the check and the sealed run stay at the old one.
  prove_part s1 receipt
  out=$(done_gate s1) || fail "the done of a lane rebased with no change must be accepted: $out"
  out=$(trunk proof s1 2>&1) || fail "a receipt at the new head with the check at the old one must be a whole proof: $out"
  out=$(trunk land s1 2>&1) || fail "the lane rebased with no change must land: $out"
  git -C "$PROJ" cat-file -e "trunk:s1.txt" || fail "the landed tip must hold the lane's change"
  [ "$(git -C "$PROJ" rev-list --count "$new..trunk")" = 0 ] || fail "the rebased head must be the landed commit: $out"
  pass 'a proved lane rebased with no change keeps its proof: no gap, the done is accepted and it lands'
}

test_a_lane_whose_change_differs_after_the_rebase_is_refused_and_named() {
  local out rc=0
  world differs; cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  # The seed's shape: the proved commit changes two files; the conflict fix rebases it and drops one file's hunk.
  lane d1 'the kept part' d1.txt
  commit_in "$W/lanes/d1" dropped.txt 'the dropped hunk' 'ticket d1 (second part)'
  git -C "$W/lanes/d1" -c user.name=t -c user.email=t@example.invalid reset -q --soft HEAD~2
  git -C "$W/lanes/d1" -c user.name=t -c user.email=t@example.invalid commit -q -m 'ticket d1'
  prove d1
  lane d0 'other work' d0.txt; trunk land d0 >/dev/null 2>&1 || fail "d0 must land"
  git -C "$W/lanes/d1" reset -q --hard trunk; commit_in "$W/lanes/d1" d1.txt 'the kept part' 'ticket d1'
  out=$(trunk proof d1 2>&1) && fail "a lane whose change differs must not keep its proof: $out"
  assert_contains "$out" "no completion receipt with verdict PASS" "the receipt of the other change is not kept"
  assert_contains "$out" "not the same change" "the gap names that the change differs"
  assert_contains "$out" "no approved merge-card evidence" "the check of the other change is not kept"
  printf '# a changed commit is refused: %s\n' "$(printf '%s' "$out" | head -n 1)"
  refused "a lane whose change differs" d1 "not the same change"
  out=$(done_gate d1) && fail "the done of a lane whose change differs must be refused: $out"
  # The same lines with another file mode are another change too.
  lane m1 'the same lines' m1.txt
  lane m0 'other work' m0.txt; trunk land m0 >/dev/null 2>&1 || fail "m0 must land"
  git -C "$W/lanes/m1" reset -q --hard trunk; printf 'the same lines\n' > "$W/lanes/m1/m1.txt"; chmod +x "$W/lanes/m1/m1.txt"
  git -C "$W/lanes/m1" add m1.txt; git -C "$W/lanes/m1" -c user.name=t -c user.email=t@example.invalid commit -q -m 'ticket m1'
  out=$(trunk proof m1 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "a commit whose file mode changed must not keep the proof: $out"
  assert_contains "$out" "not the same change" "the mode change is named as another change"
  pass 'a lane whose change differs after the rebase is refused, at the done and at the landing, and the refusal names it'
}

test_a_proved_lane_rebased_with_no_change_keeps_its_proof_and_lands
test_a_lane_whose_change_differs_after_the_rebase_is_refused_and_named
printf 'jg-trunk-proof-same-change: ok\n'
