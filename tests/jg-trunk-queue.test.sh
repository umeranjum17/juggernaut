#!/usr/bin/env bash
# Integration test for the proof a landing waits for and the merge queue of bin/jg-trunk.sh: a lane lands only with its whole
# proof at its head, lanes land in order, queued lanes land as one stack, and the gate holds no trunk lock while it runs.
# Real git repositories, a local bare origin, the real gate chain and a stub for the captain-hold reader.
#
# T12 A lane lands only with its whole proof at its head (receipt, approved merge-card evidence, sealed done-done run); the
#    owner signature never blocks it.
# T13 The journey: four lanes ready at once, three land in order with no human or lead step, the red one is refused,
#    and a commit that passes the landing check but breaks the whole suite is reverted by itself after the landing and
#    the lane is told; a revert that cannot apply cleanly writes the red pin instead.
# T14 The merge queue: 2 or more queued lanes land as ONE stack (auto-rebased in order, one gate over the union of their changed
#    files judged against the tip, one trunk move, one trunk-landings.tsv row per lane); a lane that conflicts drops out and is told; a red
#    stack is halved until only the guilty lane is returned and the green part lands; a red the whole suite finds after a batch landing is
#    traced to its one commit and reverted; a single queued lane keeps the single path.
# T15 The queue's threshold: the landing check holds ready lanes until flush-at-ready are ready or the oldest has waited
#    flush-after-minutes, then lands them all as one stack; `flush <project>` lands every ready lane at once; a lane marked
#    `land-next` lands at once, ahead of the queue, while the others keep waiting; a worker marks neither.
# tests/jg-trunk.test.sh, tests/jg-trunk-check.test.sh and tests/jg-trunk-queue.test.sh split one local trunk flow into three
# suites that each stay inside the fast set's weight limit; tests/jg-trunk-fixture.sh holds the fixture they share.
# The done-done journey journeys/trunk-landing.sh runs all three and seals their output.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-trunk-queue)
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# done_gate <id>: the worker's own done, judged by the shared acceptance the status path runs. Prints the refusal.
done_gate() {
  ( # shellcheck disable=SC1091
    . "$W/root/bin/jg-dod-lib.sh"
    JG_HOME="$HOME_D" jg_dod_accept_ship_done ship local-trunk "$W/lanes/$1" "$PROJ" "done [at=1]: ready in branch fm/$1 (local-trunk)" \
      "$HOME_D/state" "$1" "$HOME_D/state/$1.meta" 2>&1 )
}

# Every proof input is required at the lane's exact head, at the worker's done and again before a landing starts.
test_done_and_landing_both_refuse_before_starting_on_any_missing_proof_input() {
  local part out id=0 before head
  world proofgate
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  lane ok one a.txt
  out=$(done_gate ok) || fail "a done with complete matching-head proof must be accepted: $out"
  trunk proof ok >/dev/null 2>&1 || fail "the landing pre-check must accept complete matching-head proof"
  # (broken <part>, how it is broken, what the refusal must name)
  for part in receipt-absent:'completion receipt' receipt-fail:'completion receipt' receipt-stale:'completion receipt' \
              card-absent:'no approved merge-card evidence' card-stale:'no approved merge-card evidence' card-failed:'no approved merge-card evidence' \
              card-uncited:'no approved merge-card evidence' seal-absent:'no sealed done-done run' seal-stale:'no sealed done-done run' seal-dirty:'no sealed done-done run'; do
    id=$((id + 1)); lane "p$id" "v$id" "f$id.txt"
    case ${part%%:*} in
      receipt-absent) rm "$HOME_D/state/p$id.run-receipt.json" ;;
      receipt-fail) prove_part "p$id" receipt FAIL ;;
      receipt-stale) sed -i 's/"head":"[0-9a-f]*"/"head":"0000000000000000000000000000000000000000"/' "$HOME_D/state/p$id.run-receipt.json" ;;
      card-absent) rm "$HOME_D/data/p$id/merge-card.json" ;;
      card-stale) sed -i 's/"head":"[0-9a-f]*"/"head":"0000000000000000000000000000000000000000"/' "$HOME_D/data/p$id/merge-card.json" ;;
      card-failed) sed -i 's/"verdict":"pass"/"verdict":"fail"/' "$HOME_D/data/p$id/merge-card.json" ;;
      card-uncited) sed -i 's/"evidence":\[[^]]*\]/"evidence":[]/' "$HOME_D/data/p$id/merge-card.json" ;;
      seal-absent) rm -f "$HOME_D/data/p$id/.done-done/runs/"*.json ;;
      seal-stale) sed -i 's/"commit":"[0-9a-f]*"/"commit":"0000000000000000000000000000000000000000"/;s/20261109T000000Z-[0-9a-f]*/20261109T000000Z-00000000/' "$HOME_D/data/p$id/.done-done/runs/"*.json ;;
      seal-dirty) sed -i 's/"dirty":false/"dirty":true/' "$HOME_D/data/p$id/.done-done/runs/"*.json ;;
    esac
    out=$(done_gate "p$id") && fail "the done must refuse with $part: $out"
    assert_contains "$out" "${part#*:}" "the done refusal for $part must name the missing input"
    before=$(tip); head=$(git -C "$PROJ" rev-parse "fm/p$id")
    trunk proof "p$id" >/dev/null 2>&1 && fail "the landing pre-check must refuse with $part"
    out=$(trunk land "p$id" 2>&1) && fail "the landing must refuse with $part: $out"
    assert_contains "$out" "proof inputs are incomplete" "the landing refusal for $part must say the proof is incomplete"
    assert_contains "$out" "${part#*:}" "the landing refusal for $part must name the missing input"
    [ "$(tip)" = "$before" ] || fail "a landing with $part moved the trunk"
    ! git -C "$PROJ" merge-base --is-ancestor "$head" "$(tip)" || fail "a landing with $part landed the lane"
  done
  # Everything missing is named at once, in one pass, not one input per round trip.
  rm -f "$HOME_D/state/p1.run-receipt.json" "$HOME_D/data/p1/merge-card.json"
  out=$(done_gate p1) && fail "a lane with no proof must not be done"
  assert_contains "$out" "completion receipt" "all missing inputs are named together"; assert_contains "$out" "no approved merge-card evidence" "all missing inputs are named together"
  # A done at a new head needs the whole proof again; proving the new head makes both paths accept.
  commit_in "$W/lanes/ok" a.txt two "ticket ok again"
  out=$(done_gate ok) && fail "a commit after the proof voids it: $out"
  prove ok
  out=$(done_gate ok) || fail "proof at the new head must be accepted: $out"
  # The legacy local-only mode of a local-trunk project is held to the same proof; a PR mode is not subject to it.
  sed -i 's/^mode=local-trunk$/mode=local-only/' "$HOME_D/state/p2.meta"
  # shellcheck disable=SC1091
  out=$( . "$W/root/bin/jg-dod-lib.sh"; JG_HOME="$HOME_D" jg_dod_accept_ship_done ship local-only "$W/lanes/p2" "$PROJ" "done [at=1]: ready in branch fm/p2" "$HOME_D/state" p2 "$HOME_D/state/p2.meta" 2>&1 ) && fail "a legacy local-only lane of a trunk project must be held to the proof: $out"
  pass 'the worker done and the landing both refuse, before starting, on any missing proof input, and accept only complete matching-head proof'
}

# The registered check starts no landing for an incomplete proof, says why once, and lands the same head once the proof is there.
test_the_check_starts_no_landing_until_the_whole_proof_is_there() {
  local out
  world gatecheck
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  lane g1 one; rm "$HOME_D/data/g1/merge-card.json"
  out=$(sweep); assert_contains "$out" "g1 waits to land" "an incomplete proof must be reported by the check"
  assert_contains "$out" "no approved merge-card evidence" "the report names the missing input"
  [ -z "$(find "$HOME_D/data/jg-trunk-landing" -name 'g1.*.state' 2>/dev/null)" ] || fail "no landing may start for an incomplete proof"
  [ -z "$(sweep)" ] || fail "the wait must be reported once"
  [ "$(tip)" != "$(git -C "$PROJ" rev-parse fm/g1)" ] || fail "nothing may land without the proof"
  prove_part g1 card
  sweep >/dev/null; out=$(sweep)
  [ "$(tip)" = "$(git -C "$PROJ" rev-parse fm/g1)" ] || fail "the same head must land once its proof is complete: $out"
  pass 'the landing check starts nothing until the whole proof is there, then lands the same head'
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
  for _ in $(seq 1 150); do [ -s "$W/backlog-calls" ] && break; sleep 0.2; done  # the revert tells the lane just after it lands
  assert_contains "$(cat "$W/backlog-calls" 2>/dev/null)" "update j5 --append-notes" "the lane's ticket is told"
  assert_contains "$(cat "$HOME_D/state/.wake-queue")" "went red after it landed and was reverted by itself" "Overwatch is told"
  [ ! -e "$HOME_D/state/trunk-red-proj" ] || fail "a reverted red must not stop landings"
  # A revert that cannot apply cleanly writes the red pin instead, and landings stop except a fixes-red commit.
  lane k1 'echo "not ok - k1 breaks the suite" >&2; exit 1' t/k1.test.sh; trunk land k1 >/dev/null 2>&1 || fail "k1 must land by hand"
  lane k2 'exit 0' t/k1.test.sh; git -C "$W/lanes/k2" reset -q --hard trunk; commit_in "$W/lanes/k2" t/k1.test.sh 'echo "not ok - k1 breaks the suite" >&2; echo more; exit 1' "ticket k2"; prove k2
  trunk land k2 >/dev/null 2>&1 || fail "k2 must land by hand"
  rc=0; out=$(JG_HOME="$HOME_D" trunk verify "$PROJ" "$(git -C "$PROJ" log --format=%H --grep='ticket k1' -n 1 trunk)" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] && [ -e "$HOME_D/state/trunk-red-proj" ] || fail "a revert that does not apply must write the red pin: $out"
  assert_contains "$out" "could not be reverted by itself" "the red must say it could not be undone"
  pass 'three lanes land in order with no human step, the red lane is refused, and a post-land red is reverted'
}

# shellcheck disable=SC2016 # the gate bodies are written out verbatim and expand when the gate runs them
batch_world() {  # <name>: a world whose fast gate counts its runs and records the files it was asked to judge
  world "$1"
  printf 'gate-full=echo run >> "%s/gate-runs"; git diff --name-only HEAD^ >> "%s/gate-files"; ! git grep -q BAD\ngate-lint=! git grep -q UGLY\n' "$W" "$W" >> "$HOME_D/config/trunk-policy"
}
runs() { [ -f "$W/gate-runs" ] && grep -c . "$W/gate-runs" || echo 0; }

test_queued_lanes_land_as_one_stack_and_a_red_stack_is_bisected() {
  local base out rc=0 i
  batch_world batch; base=$(tip)
  # A clean stack: three lanes on the same old tip land in order, behind ONE gate over all their files, in ONE trunk move.
  lane b1 one f1.txt; lane b2 two f2.txt; lane b3 three f3.txt
  out=$(trunk land-batch b1 b2 b3 2>&1) || fail "a clean stack must land: $out"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket b1,ticket b2,ticket b3" ] || fail "the stack lands in the order given"
  [ "$(runs)" = 1 ] || fail "one gate must judge the whole stack, got $(runs) runs"
  [ "$(sort -u "$W/gate-files" | paste -sd, -)" = "f1.txt,f2.txt,f3.txt" ] || fail "the gate judges the union of the changed files: $(cat "$W/gate-files")"
  [ "$(grep -c '^landed b' <<<"$out")" = 3 ] || fail "every lane reports its landing: $out"
  [ "$(awk -F'\t' -v b="$base" '$6 == "batch-from=" b' "$HOME_D/data/trunk-landings.tsv" | wc -l | tr -d ' ')" = 3 ] || fail "one landings row per lane: $(cat "$HOME_D/data/trunk-landings.tsv")"
  [ "$(git -C "$PROJ" rev-parse fm/b3)" = "$(tip)" ] && [ -z "$(git -C "$W/lanes/b3" status --porcelain)" ] || fail "each lane follows its rebased commit"
  [ "$(grep -c '^merged' "$W/ledger-calls")" = 3 ] || fail "each lane records the same merged event: $(cat "$W/ledger-calls")"
  [ "$(cat "$HOME_D/state/trunk-tip-proj")" = "$(tip)" ] || fail "the tip record follows the one move"
  # A lane that conflicts drops out and is told, with its paths; the rest still land as one stack.
  : > "$W/gate-runs"; base=$(tip)
  lane c1 left; lane c2 right; lane c3 three f4.txt
  out=$(trunk land-batch c1 c2 c3 2>&1) || fail "a stack with one conflicting lane must still land the others: $out"
  assert_contains "$out" "returned c2: REFUSED: fm/c2 conflicts with trunk" "the conflicting lane is returned"
  assert_contains "$out" "work.txt" "the conflict names its paths"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket c1,ticket c3" ] || fail "the others land in order"
  [ "$(runs)" = 1 ] || fail "the conflict costs no extra gate run, got $(runs)"
  # A red stack is halved: the guilty lane alone is returned, the green part lands, and only the needed runs are spent.
  : > "$W/gate-runs"; base=$(tip)
  lane d1 one g1.txt; lane d2 two g2.txt; lane d3 BAD g3.txt; lane d4 four g4.txt
  out=$(trunk land-batch d1 d2 d3 d4 2>&1) || fail "a red stack must still land its green part: $out"
  assert_contains "$out" "returned d3: REFUSED: this lane is the red in its batch" "only the guilty lane is returned"
  case $out in *"returned d1"*|*"returned d2"*|*"returned d4"*) fail "a green lane must not be returned: $out" ;; esac
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket d1,ticket d2,ticket d4" ] || fail "the green part lands in order"
  [ "$(runs)" = 4 ] || fail "four lanes with one red take 4 gate runs (stack, first half, guilty, last lane), got $(runs)"
  [ "$(git -C "$PROJ" rev-parse fm/d3)" = "$(git -C "$W/lanes/d3" rev-parse HEAD)" ] || fail "the returned lane is left exactly as it was"
  ! git -C "$PROJ" cat-file -e trunk:g3.txt 2>/dev/null || fail "the red lane's change is not on the trunk"
  # One queued lane keeps the single path, and the batch refuses what a single landing refuses.
  rc=0; out=$(trunk land-batch lonely 2>&1) || rc=$?; [ "$rc" -ne 0 ] || fail "a batch of one is refused: $out"
  assert_contains "$out" "2 or more" "a lone lane is told to use land"
  for i in --force -f; do out=$(trunk land-batch d3 d4 "$i" 2>&1) && fail "a batch is never forced"; done
  pass 'queued lanes land as one stack: one gate, one move, a conflict drops out, a red stack is halved to the guilty lane'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_red_the_suite_finds_after_a_batch_is_traced_to_its_one_commit_and_reverted() {
  local base out rc=0 top
  world batchrev; rig; base=$(tip)
  printf 'gate-full=true\ngate-verify=bash %s/rig.sh --all\n' "$W" >> "$HOME_D/config/trunk-policy"
  lane e1 'exit 0' t/e1.test.sh; lane e2 'echo "not ok - e2 breaks the suite" >&2; exit 1' t/e2.test.sh; lane e3 'exit 0' t/e3.test.sh
  trunk land-batch e1 e2 e3 >/dev/null 2>&1 || fail "the fast gate passes all three, so the stack lands"
  top=$(tip)
  out=$(trunk verify "$PROJ" "$top" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the whole suite is red after this stack: $out"
  git -C "$PROJ" log -1 --format=%s trunk | grep -q '^Revert "ticket e2"' || fail "the lane that broke the suite is reverted, not the top of the stack: $(git -C "$PROJ" log --format=%s "$base..trunk")"
  git -C "$PROJ" cat-file -e trunk:t/e2.test.sh 2>/dev/null && fail "e2's change is undone on the tip"
  git -C "$PROJ" cat-file -e trunk:t/e1.test.sh || fail "e1 stays on the trunk"
  git -C "$PROJ" cat-file -e trunk:t/e3.test.sh || fail "e3 stays on the trunk"
  [ ! -e "$HOME_D/state/trunk-red-proj" ] || fail "a reverted red does not stop landings"
  assert_contains "$out" "e2" "the revert names the lane"
  pass 'a red the whole suite finds after a batch is traced to the one commit that caused it and reverted by itself'
}

# shellcheck disable=SC2016 # the gate bodies are written out verbatim and expand when the gate runs them
test_the_landing_check_stacks_ready_lanes_and_keeps_a_single_lane_on_its_own_path() {
  local base out n
  batch_world watcherbatch; base=$(tip)
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  lane w1 one f1.txt; lane w2 left; lane w3 right; lane w4 four f4.txt
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null
  for _ in $(seq 1 150); do [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" -ge 3 ] && ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && break; sleep 0.2; done
  n=$(git -C "$PROJ" rev-list --count "$base..trunk")
  [ "$n" = 3 ] || fail "three of four ready lanes land, got $n: $(git -C "$PROJ" log --format=%s "$base..trunk")"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket w1,ticket w2,ticket w4" ] || fail "they land in the order they were done"
  [ "$(runs)" = 1 ] || fail "the ready lanes were judged by one gate, got $(runs) runs"
  [ "$(paste -sd, - < "$W/teardown-calls")" = "w1,w2,w4" ] || fail "each landed lane is cleaned up, unforced, in order: $(cat "$W/teardown-calls")"
  out=$(JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D")
  assert_contains "$out" "w3 not landed" "the conflicting lane is reported"
  assert_contains "$out" "work.txt" "its report names the conflicting path"
  [ -z "$(JG_HOME="$HOME_D" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D")" ] || fail "the refusal is reported once"
  for _ in $(seq 1 150); do [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] && break; sleep 0.2; done
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] || fail "the whole suite runs once on the stack's top and moves the green pin"
  # A single ready lane keeps the single path: its own landing, no stack.
  : > "$W/gate-runs"; lane w5 five f5.txt
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null
  for _ in $(seq 1 150); do git -C "$PROJ" log --format=%s trunk | grep -q '^ticket w5' && break; sleep 0.2; done
  git -C "$PROJ" log --format=%s trunk | grep -q '^ticket w5' || fail "a single ready lane lands"
  ! grep -q 'batch-from' <(grep '^w5' "$HOME_D/data/trunk-landings.tsv") || fail "a single lane is not recorded as part of a stack"
  for _ in $(seq 1 150); do [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] && break; sleep 0.2; done  # let its whole-suite run end before the fixture goes
  pass 'the landing check stacks the ready lanes into one landing and a single lane keeps its own path'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_queued_verifies_run_one_at_a_time_and_only_the_newest_runs() {
  local c1 c2 c3 p1 p2 p3 n
  world coalesce
  lane q1 one; c1=$(tip_after_land q1); lane q2 two; c2=$(tip_after_land q2); lane q3 three; c3=$(tip_after_land q3)
  # A whole-suite run that records which commit it ran at and stays open until the test releases it.
  printf '#!/usr/bin/env bash\ngit rev-parse HEAD >> %s/verify-ran\nwhile [ ! -e %s/release ]; do sleep 0.1; done\n' "$W" "$W" > "$W/slow.sh"
  printf 'gate-verify=bash %s/slow.sh\n' "$W" >> "$HOME_D/config/trunk-policy"
  trunk verify "$PROJ" "$c1" > "$W/v1.out" 2>&1 & p1=$!
  for n in $(seq 1 100); do [ -s "$W/verify-ran" ] && break; sleep 0.1; done
  [ -s "$W/verify-ran" ] || fail "the first verify must be running"
  # Two more are queued behind it. The older one gives up at once; only the newest waits for the slot.
  trunk verify "$PROJ" "$c2" > "$W/v2.out" 2>&1 & p2=$!
  trunk verify "$PROJ" "$c3" > "$W/v3.out" 2>&1 & p3=$!
  wait "$p2" || fail "a superseded verify must end quietly: $(cat "$W/v2.out")"
  assert_contains "$(cat "$W/v2.out")" "superseded" "the older queued verify must say a newer one took its place"
  : > "$W/release"
  wait "$p1" || fail "the running verify must finish: $(cat "$W/v1.out")"
  wait "$p3" || fail "the newest verify must run and pass: $(cat "$W/v3.out")"
  [ "$(cat "$W/verify-ran")" = "$c1"$'\n'"$c3" ] || fail "the suite must run at the first and the newest commit only: $(cat "$W/verify-ran")"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$c3" ] || fail "green at the newest commit moves the pin over the commit that never ran"
  [ ! -e "$HOME_D/state/trunk-verify-want-proj" ] || fail "a verify that ended must leave nothing queued"
  # A verify for a commit that is already under the pin does not run the suite again.
  assert_contains "$(trunk verify "$PROJ" "$c2" 2>&1)" "already under the green pin" "a covered commit is not verified again"
  [ "$(grep -c . "$W/verify-ran")" = 2 ] || fail "a covered commit must not run the suite"
  pass 'queued verifies run one at a time and only the newest runs; its green moves the pin over the rest'
}
# tip_after_land <id>: lands the lane and prints the new trunk tip.
tip_after_land() { trunk land "$1" >/dev/null 2>&1 || fail "$1 must land"; tip; }

# A gate that records what it judged and stays open, until the test releases it, on a commit whose tree holds SLOW.
slow_gate() {
  printf '#!/usr/bin/%s bash\ngit log -1 --format=%%s >> %s/gate-seen\nif git grep -q SLOW; then while [ ! -e %s/release ]; do sleep 0.1; done; fi\n' env "$W" "$W" > "$W/slow-gate.sh"
  printf 'gate-full=bash %s/slow-gate.sh\n' "$W" >> "$HOME_D/config/trunk-policy"
}
seen() { local n; n=$(grep -c "^$1\$" "$W/gate-seen" 2>/dev/null || :); echo "${n:-0}"; }  # how often the gate judged the commit with this subject
await_gate() {  # <subject>: until the gate is judging it
  local n; for n in $(seq 1 150); do [ "$(seen "$1")" -ge 1 ] && return 0; sleep 0.1; done; fail "the gate must start on $1"
}

test_a_landing_does_not_hold_the_trunk_while_its_gate_runs() {
  local c0 p1 out
  world longland
  lane l0 one; c0=$(tip_after_land l0); slow_gate
  lane l1 SLOW slow.txt; lane l3 three other.txt
  trunk land l1 > "$W/l1.out" 2>&1 & p1=$!
  await_gate 'ticket l1'
  # While the long landing is in its gate, a verify reads the tip, runs and moves the pin, and another lane lands.
  out=$(timeout 60 env PATH="$W/fakebin:$PATH" JG_HOME="$HOME_D" JG_ROOT_OVERRIDE="$W/root" JG_STATE_OVERRIDE="$HOME_D/state" JG_DATA_OVERRIDE="$HOME_D/data" JG_CONFIG_OVERRIDE="$HOME_D/config" "$W/root/bin/jg-trunk.sh" verify "$PROJ" "$c0" 2>&1) || fail "a verify must finish while a landing's gate runs: $out"
  kill -0 "$p1" 2>/dev/null || fail "the long landing must still be gating when the verify ends: $(cat "$W/l1.out")"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$c0" ] || fail "the verify must move the pin while the landing is gating"
  out=$(trunk land l3 2>&1) || fail "another lane must land while a landing is gating: $out"
  # The long landing's tip moved under it, so it is rebased onto the new tip and gated again; it lands once the gate is released.
  : > "$W/release"; wait "$p1" || fail "the long landing must land after its tip moved: $(cat "$W/l1.out")"
  assert_contains "$(cat "$W/l1.out")" "while l1 was gated" "the landing must say it gated again on the new tip"
  [ "$(seen 'ticket l1')" = 2 ] || fail "the lane must be gated again on the new tip, got $(seen 'ticket l1') runs"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$c0..trunk" | paste -sd, -)" = "ticket l3,ticket l1" ] || fail "both lanes land, in the order they were ready to move the trunk"
  [ "$(cat "$HOME_D/state/trunk-tip-proj")" = "$(tip)" ] || fail "the tip record follows the trunk"
  pass 'a landing holds no trunk lock while its gate runs: a verify finishes and moves the pin, another lane lands, and the first is re-gated on the new tip'
}

test_a_stack_holds_no_trunk_lock_while_its_gate_runs_and_is_judged_again_on_a_moved_tip() {
  local base p1 out
  world longstack; base=$(tip); slow_gate
  lane s1 SLOW slow.txt; lane s2 two f2.txt; lane s3 three other.txt
  trunk land-batch s1 s2 > "$W/b.out" 2>&1 & p1=$!
  await_gate 'ticket s2'
  out=$(trunk land s3 2>&1) || fail "a lane must land while a stack is gating: $out"
  : > "$W/release"; wait "$p1" || fail "the stack must land after its tip moved: $(cat "$W/b.out")"
  assert_contains "$(cat "$W/b.out")" "moved while the stack was gated" "the stack must say it judged again"
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)" = "ticket s3,ticket s1,ticket s2" ] || fail "the stack lands on top of the lane that moved the trunk"
  [ "$(grep -c '^landed s' "$W/b.out")" = 2 ] || fail "both lanes of the stack land: $(cat "$W/b.out")"
  pass 'a stack holds no trunk lock while its gate runs and is judged again when the trunk moved under it'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_verify_moves_the_pin_over_a_red_its_parent_already_had() {
  local out good
  world parentred; rig; seed_red_tip
  printf 'gate-verify=export GATE_MARK=yes; bash %s/rig.sh --all\n' "$W" >> "$HOME_D/config/trunk-policy"
  lane good 'exit 0' t/d.test.sh
  trunk land good >/dev/null 2>&1 || fail "a lane that adds no red must land on a red tip"
  good=$(tip)
  out=$(trunk verify "$PROJ" 2>&1) || fail "a verify whose only failure is its parent's own must pass: $out"
  assert_contains "$out" "already had set aside" "the verify must say it set the parent's red aside"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$good" ] || fail "the pin must move when every failure is one the parent already had"
  # A red the commit adds still holds the pin and is charged to the commit.
  lane bad 'echo "not ok - new red" >&2; exit 1' t/e.test.sh
  printf 'gate-full=true\n' >> "$HOME_D/config/trunk-policy"
  trunk land bad >/dev/null 2>&1 || fail "the lane lands by hand past a fast gate"
  trunk verify "$PROJ" >/dev/null 2>&1 && fail "a commit that adds a red must not pass verify"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$good" ] || fail "a red the commit added must not move the pin"
  pass 'the green pin moves over failures the parent already had, and holds on a red the commit added'
}

# fresh <id> <minutes>: the lane's done report is this many minutes old.
fresh() { printf 'done [at=%s]: ready in branch fm/%s (local-trunk)\n' "$(( $(date +%s) - $2 * 60 ))" "$1" >> "$HOME_D/state/$1.status"; }
qsweep() { JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" 2>&1; }
# settled <n>: the trunk holds <n> commits over <base> and the whole suite has moved the green pin to its tip.
settled() {
  local _
  for _ in $(seq 1 150); do
    [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = "$1" ] && [ "$(cat "$HOME_D/state/trunk-green-proj" 2>/dev/null)" = "$(tip)" ] && ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && return 0
    sleep 0.2
  done
  fail "the trunk must hold $1 landed lanes and a settled suite: $(git -C "$PROJ" log --format=%s "$base..trunk" | paste -sd, -)"
}
unlanded() { [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = "$1" ] || fail "$2: $(git -C "$PROJ" log --format=%s "$base..trunk" | paste -sd, -)"; }

# shellcheck disable=SC2016 # the gate bodies are written out verbatim and expand when the gate runs them
test_the_queue_flushes_at_a_threshold_on_a_command_and_a_marked_lane_jumps_it() {
  local base out rc=0
  batch_world flushq; base=$(tip)
  printf 'flush-at-ready=3\nflush-after-minutes=20\n' >> "$HOME_D/config/trunk-policy"
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  # Below the threshold and young: two ready lanes wait; nothing lands one by one.
  lane q1 one f1.txt; lane q2 two f2.txt; fresh q1 5; fresh q2 4
  qsweep >/dev/null; unlanded 0 "two young lanes are below flush-at-ready and wait"
  # The third lane reaches the threshold: all three land in ONE stack behind ONE gate.
  lane q3 three f3.txt; fresh q3 3
  qsweep >/dev/null; settled 3
  [ "$(runs)" = 1 ] || fail "the flushed lanes were judged by one gate, got $(runs) runs"
  [ "$(awk -F'\t' '$6 ~ /^batch-from=/' "$HOME_D/data/trunk-landings.tsv" | wc -l | tr -d ' ')" = 3 ] || fail "the three landed as one stack"
  # One lane that has waited past flush-after-minutes lands by itself.
  base=$(tip); lane q4 four f4.txt; fresh q4 19
  qsweep >/dev/null; unlanded 0 "a lane that has waited 19 of 20 minutes still waits"
  fresh q4 21; qsweep >/dev/null; settled 1
  # `flush` lands every ready lane now, whatever the threshold says, and the request ends once the queue is empty.
  base=$(tip); lane q5 five f5.txt; lane q6 six f6.txt; fresh q5 2; fresh q6 1
  qsweep >/dev/null; unlanded 0 "two young lanes wait"
  out=$(JG_TASK_ID=q5 trunk flush "$PROJ" 2>&1) && fail "a worker never flushes the queue"; assert_contains "$out" "a worker never flushes" "the worker refusal says why"
  out=$(trunk flush "$PROJ" 2>&1) || fail "Overwatch can flush the queue: $out"; assert_contains "$out" "flush requested for proj" "flush says what it did"
  [ -e "$HOME_D/state/trunk-flush-proj" ] || fail "flush records its request"
  : > "$W/gate-runs"; qsweep >/dev/null; settled 2
  [ "$(runs)" = 1 ] || fail "flush lands the ready lanes as one stack, got $(runs) gate runs"
  qsweep >/dev/null; [ ! -e "$HOME_D/state/trunk-flush-proj" ] || fail "the flush request ends when no ready lane is left"
  # A lane marked land-next lands at once, ahead of the queue; the lanes below the threshold keep waiting.
  base=$(tip); lane q7 seven f7.txt; lane q9 nine f9.txt; fresh q7 3; fresh q9 1
  out=$(JG_TASK_ID=q9 trunk land-next q9 2>&1) && fail "a worker never marks a lane to land next"
  out=$(trunk land-next nosuch 2>&1) && fail "land-next needs a real task"; assert_contains "$out" "usage: jg-trunk.sh land-next" "land-next names its usage"
  trunk land-next q9 >/dev/null || fail "Overwatch can mark a lane to land next"
  qsweep >/dev/null; settled 1
  [ "$(git -C "$PROJ" log --format=%s "$base..trunk")" = "ticket q9" ] || fail "only the marked lane lands, the older lane waits"
  [ ! -e "$HOME_D/state/q9.land-next" ] || fail "the mark ends when the lane lands"
  # Marked while the threshold is met (q7 waits, q10 is marked, q11 arrives): the marked lane lands first, in the same stack as the rest.
  lane q10 ten f10.txt; lane q11 eleven f11.txt; fresh q10 2; fresh q11 1; trunk land-next q10 >/dev/null
  qsweep >/dev/null; settled 4
  [ "$(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | sed -n 2p)" = "ticket q10" ] || fail "the marked lane goes first: $(git -C "$PROJ" log --reverse --format=%s "$base..trunk" | paste -sd, -)"
  pass 'the queue lands at a threshold, flushes on a command, and a land-next lane jumps it'
}

test_done_and_landing_both_refuse_before_starting_on_any_missing_proof_input
test_the_check_starts_no_landing_until_the_whole_proof_is_there
test_three_lanes_land_in_order_a_red_one_is_refused_and_a_post_land_red_is_reverted
test_queued_lanes_land_as_one_stack_and_a_red_stack_is_bisected
test_a_red_the_suite_finds_after_a_batch_is_traced_to_its_one_commit_and_reverted
test_the_landing_check_stacks_ready_lanes_and_keeps_a_single_lane_on_its_own_path
test_queued_verifies_run_one_at_a_time_and_only_the_newest_runs
test_a_verify_moves_the_pin_over_a_red_its_parent_already_had
test_a_landing_does_not_hold_the_trunk_while_its_gate_runs
test_a_stack_holds_no_trunk_lock_while_its_gate_runs_and_is_judged_again_on_a_moved_tip
test_the_queue_flushes_at_a_threshold_on_a_command_and_a_marked_lane_jumps_it
printf 'jg-trunk-queue: ok\n'
