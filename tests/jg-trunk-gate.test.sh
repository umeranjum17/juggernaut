#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh: the landing gate and the proof a lane lands with (tests/jg-trunk-fixture.sh).
# Through tests/jg-trunk-fixture.sh it runs bin/jg-trunk.sh, reads bin/jg-dod-lib.sh and stands in for bin/jg-captain-hold.sh,
# bin/jg-backlog.sh, bin/jg-send.sh, bin/jg-teardown.sh, bin/jg-fleet-ledger.sh and bin/jg-home-health.sh.
#
# T11 The landing gate charges a lane only for what it broke: a script red on the trunk tip in the same way does not block
#    (it is reported once per tip tree, and the green pin stays), while a script that fails only on the lane, passes on the
#    tip, or fails differently on the lane blocks it, with the tip's rerun done in the environment the gate ended with.
#    A failure gets one rerun on the lane before it is judged: one that passes on the rerun is flaky and not charged, and is
#    recorded and filed once as its own fix row.
# T12 A landing is one fast check: the lander rebases the lane's one commit onto the tip by itself (the lane follows it),
#    and a lane lands only with its whole proof at its head (receipt, approved merge-card evidence, sealed done-done run); the owner signature never blocks it.
# T13 The journey: four lanes ready at once, three land in order with no human or lead step, the red one is refused,
#    and a commit that passes the landing check but breaks the whole suite is reverted by itself after the landing and
#    the lane is told; a revert that cannot apply cleanly raises one alert, pins nothing, and the next lane still lands.
# The done-done journey journeys/trunk-landing.sh runs this file and seals its output.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

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
  assert_contains "$(tail -n 1 "$HOME_D/data/trunk-landing-proofs.tsv")" "$(printf 'good\tproj\t%s' "$(tip)")" "the landing's proofs row must be the last one"
  [[ $(tail -n 1 "$HOME_D/data/trunk-landing-proofs.tsv") =~ gate=ran:[1-9][0-9]*,failed:[1-9][0-9]*,secs:[0-9]+$ ]] \
    || fail "the proofs row must keep the gate's scripts run, failed on the first run and seconds: $(tail -n 1 "$HOME_D/data/trunk-landing-proofs.tsv")"
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
  assert_contains "$(grep '^add flaky-proj-f ' "$W/backlog-calls")" "[blocker] flaky test t/f.test.sh" "the flaky test is filed as its own fix row"
  assert_contains "$(cat "$HOME_D/data/trunk/flaky-proj.tsv")" "t/f.test.sh" "the flaky test is recorded"
  # The same script failing on both runs is the lane's own failure.
  lane twice 'echo "not ok - solid case" >&2; exit 1' t/g.test.sh
  refused 'a failure that repeats on the rerun' twice 't/g.test.sh'
  pass 'a failure gets one rerun before it is judged: a flaky one is set aside and filed as its own row, a repeated one blocks'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_tip_red_that_prints_its_elapsed_seconds_is_the_same_red_on_every_run() {
  local out
  world elapsed; rig
  git -C "$PROJ" worktree add -q -b seed "$W/seed" trunk
  # A Go test prints its run time on the last line, so the tip's red reads differently on every run.
  commit_in "$W/seed" t/h.test.sh '[ "${GATE_MARK:-}" = yes ] || exit 0; n=$(cat '"$W"'/runs 2>/dev/null || echo 0); echo $((n + 1)) > '"$W"'/runs; printf "FAIL\\tpkg/x\\t2%s.%s3s\\n" "$n" "$n" >&2; exit 1' "seed h"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/seed" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
  lane good 'exit 0' t/d.test.sh
  out=$(trunk land good 2>&1) || fail "a lane must land beside a tip red that differs from its own run only by elapsed seconds: $out"
  assert_contains "$out" "not charged to this lane" "the tip's red is set aside"
  pass "a tip red that prints its elapsed seconds is the same red on every run, so no lane is charged for it"
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_the_gates_are_policy_keys_with_fast_defaults() {
  local key
  pol() { JG_CONFIG_OVERRIDE="$TMP_ROOT/no-config" bash -c ". '$ROOT/bin/jg-trunk-policy-lib.sh'; jg_trunk_policy $1"; }
  assert_contains "$(pol gate-lint)" "--changed-base HEAD^" "the landing lint must cover the changed files only"
  assert_contains "$(pol gate-full)" "--required-shards HEAD^" "the landing tests must be the changed files' tests, run as the parallel shards"
  case $(pol gate-full) in *"--all"*) fail "the landing must not run the whole suite" ;; esac
  assert_contains "$(pol gate-verify)" "bin/jg-test-run.sh --all" "verify must run the whole suite"
  for key in gate-mode gate-smoke owner-rules; do pol "$key" >/dev/null 2>&1 && fail "the retired policy key $key must be gone"; done
  pass 'the landing gates are policy keys: the lint and tests cover the changed files, the whole suite is verify'"'"'s'
}

# shellcheck disable=SC2016 # the policy lines are written out verbatim and expand when the gate runs them
test_a_project_that_is_not_juggernaut_never_runs_juggernauts_gates() {
  local out rc=0 sha lib="$ROOT/bin/jg-trunk-policy-lib.sh"
  world foreign
  rm -f "$HOME_D/config/trunk-policy"  # no override at all: the built-in defaults decide, and they are Juggernaut's own suite
  # The fixture tracks a file under data/, which Juggernaut's own invariant would reject silently (an empty log, a verify that never passes).
  lane f1 one data/notes.txt
  out=$(trunk land f1 2>&1) || fail "a project with no gates set must land with none run: $out"
  assert_contains "$out" "no landing gate" "the landing must say it ran no gate"
  assert_contains "$(cat "$HOME_D/data/trunk-landings.tsv")" "no-gate" "the landing must record that no gate ran"
  sha=$(tip)
  out=$(trunk verify "$PROJ" "$sha" 2>&1) || fail "verify with no gate must not fail: $out"
  assert_contains "$out" "no verify gate for proj" "verify must say it had no gate"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$sha" ] || fail "verify with no gate must leave the trunk green so the home can go on"
  # The project's own gate-full is its verify gate when it set no gate-verify; its own gate-verify wins over it; both fail for real.
  printf 'gate-full@proj=test ! -e BAD\n' > "$HOME_D/config/trunk-policy"
  out=$(bash -c ". '$lib'; JG_CONFIG_OVERRIDE='$HOME_D/config' jg_trunk_gate gate-verify proj '$PROJ' trunk")
  [ "$out" = 'test ! -e BAD' ] || fail "a project with only gate-full@proj must verify with it, got '$out'"
  printf 'gate-full@proj=true\ngate-verify@proj=false\n' > "$HOME_D/config/trunk-policy"
  out=$(bash -c ". '$lib'; JG_CONFIG_OVERRIDE='$HOME_D/config' jg_trunk_gate gate-verify proj '$PROJ' trunk")
  [ "$out" = false ] || fail "gate-verify@proj must win over gate-full@proj, got '$out'"
  rc=0; trunk verify "$PROJ" "$sha" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a project's own failing gate-verify must still fail verify"
  # A repository that carries Juggernaut's own suite keeps the built-in defaults.
  mkdir -p "$W/self/bin"; : > "$W/self/bin/jg-test-run.sh"; git init -q "$W/self"; git -C "$W/self" add -A
  git -C "$W/self" -c user.name=t -c user.email=t@example.invalid commit -q -m self
  out=$(bash -c ". '$lib'; JG_CONFIG_OVERRIDE='$W/none' jg_trunk_gate gate-verify self '$W/self' HEAD")
  assert_contains "$out" "bin/jg-test-run.sh --all" "the Juggernaut repository must keep its built-in verify gate"
  out=$(bash -c ". '$lib'; JG_CONFIG_OVERRIDE='$W/none' jg_trunk_gate gate-verify proj '$PROJ' trunk") && fail "another project must have no built-in gate, got '$out'"
  pass 'a project that is not Juggernaut runs only the gates its home set for it'
}

test_a_landing_rebases_the_lane_by_itself() {
  local out rows c1 c2 c3
  world rebase
  # The merge gate of this home refuses every merge for a missing signature: a landing no longer asks it.
  printf '#!/usr/bin/env bash\necho "merge refused: no valid local proof signature" >&2\nexit 1\n' > "$HOME_D/config/merge-gate"; chmod +x "$HOME_D/config/merge-gate"
  lane r1 one a.txt; lane r2 two b.txt; lane r3 three c.txt
  c1=$(git -C "$PROJ" rev-parse fm/r1)
  out=$(trunk land r1 2>&1) || fail "a lane with its whole proof must land: $out"
  [ "$(tip)" = "$c1" ] || fail "r1 must be on the trunk as it is"
  # r2 is based on the old tip: the lander rebases it (its proof is for the head it reported), the lane follows, its worktree stays clean.
  c2=$(git -C "$PROJ" rev-parse fm/r2)
  out=$(trunk land r2 2>&1) || fail "a lane on a moved tip must land by being rebased: $out"
  [ "$(tip)" != "$c2" ] && [ "$(git -C "$PROJ" rev-parse "$(tip)^")" = "$c1" ] || fail "the rebased commit must sit directly on the previous tip"
  [ "$(git -C "$PROJ" rev-parse fm/r2)" = "$(tip)" ] || fail "the lane must follow its rebased commit"
  [ -z "$(git -C "$W/lanes/r2" status --porcelain)" ] && [ "$(git -C "$W/lanes/r2" rev-parse HEAD)" = "$(tip)" ] || fail "the lane's worktree must follow the rebase and stay clean"
  [ "$(git -C "$PROJ" log -1 --format=%s "$(tip)")" = "ticket r2" ] || fail "the rebased commit must keep the lane's message"
  # A lane whose worktree has unsaved work lands, and the work is left alone.
  printf 'unsaved\n' > "$W/lanes/r3/scratch.txt"
  out=$(trunk land r3 2>&1) || fail "a lane with unsaved work in its copy must land: $out"
  c3=$(git -C "$PROJ" rev-parse fm/r3)
  [ "$(tip)" != "$c3" ] && [ -f "$W/lanes/r3/scratch.txt" ] || fail "unsaved work in the lane must be left exactly as it was"
  rows=$(cat "$HOME_D/data/trunk-landing-proofs.tsv")
  assert_contains "$rows" "$(printf 'r1\tproj\t%s' "$c1")" "the landing must be recorded with its facts"
  assert_contains "$rows" "receipt=PASS@" "the sealed receipt is recorded with the landing"
  assert_contains "$rows" "signature=absent" "a missing signature is recorded as absent and never blocks"
  assert_contains "$rows" "merge-card=present" "the merge-card is recorded"
  assert_contains "$rows" "gate=ran:-,failed:-,secs:" "a gate that prints no script summary is recorded with its seconds only"
  # A change that really conflicts is still refused, with its paths, and is never rebased dirty.
  lane x1 left; lane x2 right
  trunk land x1 >/dev/null 2>&1 || fail "x1 must land"
  refused 'a conflicting lane' x2 'conflicts with trunk'
  assert_contains "$(trunk land x2 2>&1)" 'in: work.txt' 'a conflict names its paths'
  pass 'the lander rebases a lane by itself; only the owner signature stays outside the landing'
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
  out=$(done_gate p2 local-only "done [at=1]: ready in branch fm/p2") && fail "a legacy local-only lane of a trunk project must be held to the proof: $out"
  pass 'the worker done and the landing both refuse, before starting, on any missing proof input, and accept only complete matching-head proof'
}

# When merge-card refuses a sealed run for a reason it names, the proof gap says that reason. It never says no run exists when a run
# does (the lane that cited a Designs capture was told "no sealed run" while its run was sealed and judged).
test_a_proof_gap_names_the_reason_merge_card_refused_not_a_missing_run() {
  local out card
  world gapreason
  lane r1 one
  trunk proof r1 >/dev/null 2>&1 || fail "the fixture lane must have complete proof before it is broken"
  card="$HOME_D/data/r1/merge-card.json"
  jq --arg home "$HOME_D/dd" '. + {context: {home: $home, account: "", project: "", config_hash: "0000000000000000000000000000000000000000"}}' "$card" > "$card.tmp" && mv "$card.tmp" "$card"
  out=$(trunk proof r1 2>&1) && fail "a refused sealed run must leave a proof gap: $out"
  assert_contains "$out" "was refused: proof configuration changed since the passed check" "the gap must name the reason merge-card gave"
  case $out in *"no sealed done-done run"*) fail "a refusal with a named reason must not be reported as a missing run: $out" ;; esac
  out=$(trunk land r1 2>&1) && fail "the landing must refuse the same lane: $out"
  assert_contains "$out" "was refused: proof configuration changed since the passed check" "the landing refusal must name the same reason"
  pass 'a refused sealed run is reported with merge-card'"'"'s own reason, not as a missing run'
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
  # A revert that cannot apply cleanly raises one alert and pins nothing: the green pin stays on the last green commit, and the next lane lands.
  lane k1 'echo "not ok - k1 breaks the suite" >&2; exit 1' t/k1.test.sh; trunk land k1 >/dev/null 2>&1 || fail "k1 must land by hand"
  lane k2 'exit 0' t/k1.test.sh; git -C "$W/lanes/k2" reset -q --hard trunk; commit_in "$W/lanes/k2" t/k1.test.sh 'echo "not ok - k1 breaks the suite" >&2; echo more; exit 1' "ticket k2"; prove k2
  trunk land k2 >/dev/null 2>&1 || fail "k2 must land by hand"
  sha=$(cat "$HOME_D/state/trunk-green-proj")
  rc=0; out=$(JG_HOME="$HOME_D" trunk verify "$PROJ" "$(git -C "$PROJ" log --format=%H --grep='ticket k1' -n 1 trunk)" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a red that cannot be reverted is not green: $out"
  assert_contains "$out" "could not be reverted by itself; landings go on, and live stays on the last green commit ${sha:0:12}" "the red must say it could not be undone and that landings go on"
  assert_contains "$(cat "$HOME_D/state/.wake-queue")" "could not be reverted by itself" "Overwatch is told once"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$sha" ] || fail "an unreverted red leaves the green pin on the last green commit"
  lane k3 'exit 0' t/k3.test.sh; out=$(trunk land k3 2>&1) || fail "a red that could not be reverted never stops the next landing: $out"
  pass 'three lanes land in order with no human step, the red lane is refused, and a post-land red is reverted'
}

test_the_full_gate_charges_a_lane_only_for_what_it_broke
test_a_flaky_failure_gets_one_rerun_before_it_is_judged
test_a_tip_red_that_prints_its_elapsed_seconds_is_the_same_red_on_every_run
test_the_gates_are_policy_keys_with_fast_defaults
test_a_project_that_is_not_juggernaut_never_runs_juggernauts_gates
test_a_landing_rebases_the_lane_by_itself
test_done_and_landing_both_refuse_before_starting_on_any_missing_proof_input
test_a_proof_gap_names_the_reason_merge_card_refused_not_a_missing_run
test_the_check_starts_no_landing_until_the_whole_proof_is_there
test_three_lanes_land_in_order_a_red_one_is_refused_and_a_post_land_red_is_reverted
printf 'jg-trunk-gate: ok\n'
