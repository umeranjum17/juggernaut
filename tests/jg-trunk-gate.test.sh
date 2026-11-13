#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh: the landing gate and the proof a lane lands with (tests/jg-trunk-fixture.sh).
# Through tests/jg-trunk-fixture.sh it runs bin/jg-trunk.sh, reads bin/jg-dod-lib.sh and stands in for bin/jg-captain-hold.sh,
# bin/jg-backlog.sh, bin/jg-send.sh, bin/jg-teardown.sh, bin/jg-fleet-ledger.sh and bin/jg-home-health.sh.
#
# T11 The landing gate charges a lane only for what it broke: a script red on the trunk tip in the same way does not block
#    (it is reported once per tip tree), while a script that fails only on the lane, passes on the
#    tip, or fails differently on the lane blocks it, with the tip's rerun done in the environment the gate ended with.
#    A failure gets one rerun on the lane before it is judged: one that passes on the rerun is flaky and not charged, and is
#    recorded and filed once as its own fix row. A lane is charged for a script only when its parent passes it 3 of 3: one that
#    fails by itself on the parent is flaky, lands, and is filed once.
# T12 A landing is one fast check: the lander rebases the lane's one commit onto the tip by itself (the lane follows it),
#    and a lane lands only with its whole proof at its head (receipt, approved merge-card evidence, sealed done-done run); the owner signature never blocks it.
# T13 The journey: four lanes ready at once, three land in order with no human or lead step, the red one is refused, no
#    landing moves the green pin, and no landing runs a whole suite or moves the pin (the tick's verify does), so a whole suite that would be red
#    (a shard over its time budget, as trunk-v3 at 9f5bbb3af0d1) stops no landing. A green pin left 6 hours behind 9 landings
#    moves to the next landing's head, and the landing's check judges that lane's changed scripts alone, however many landings
#    sit above the release base. A red a hand-run verify finds is reverted by itself, takes the green pin back below it and
#    the lane is told; a revert that cannot apply cleanly raises one alert, takes the pin back too, and the next lane still lands.
# The done-done journey journeys/trunk-landing.sh runs this file and seals its output.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"
JG_TRUNK_FIXTURE_CACHE=1

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_the_full_gate_charges_a_lane_only_for_what_it_broke() {
  local out tipc
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
  [ "$(grep -c '^update ticket-red ' "$W/backlog-calls")" = 1 ] || fail "the tip's red must be noted once: $(cat "$W/backlog-calls")"
  [ "$(grep -c 'alert-line-red--proj-tip-' "$HOME_D/state/.wake-queue")" = 1 ] || fail "the tip's red must raise one alert: $(cat "$HOME_D/state/.wake-queue" 2>&1)"
  assert_contains "$(cat "$W/backlog-calls")" "update ticket-red --append-notes" "the note goes to the red ticket"
  assert_contains "$(cat "$W/backlog-calls")" "t/a.test.sh" "the note names the red script"
  [ "$(grep -c '^t/a.test.sh' "$HOME_D/data/trunk/"tip-results-proj-*.tsv)" = 1 ] || fail "the tip's result for a script is computed once"
  assert_contains "$(cat "$HOME_D/data/trunk/tip-red-reported-proj.tsv")" "t/a.test.sh" "the report is recorded by script and tip tree"
  [ "$(tip)" = "$tipc" ] || fail "no refused lane moves the trunk"
  # A lane that touches only what is unrelated lands; the tip's red is set aside, not charged, and its gate moves no pin.
  lane good 'exit 0' t/d.test.sh
  out=$(trunk land good 2>&1) || fail "a lane that adds no red must land on a red tip: $out"
  assert_contains "$out" "not charged to this lane" "the landing must say it set the tip's red aside"
  assert_contains "$out" "gate=full-tip-red" "the landing must record that the gate was set against the tip"
  assert_contains "$(tail -n 1 "$HOME_D/data/trunk-landing-proofs.tsv")" "$(printf 'good\tproj\t%s' "$(tip)")" "the landing's proofs row must be the last one"
  [[ $(tail -n 1 "$HOME_D/data/trunk-landing-proofs.tsv") =~ gate=ran:[1-9][0-9]*,failed:[1-9][0-9]*,secs:[0-9]+[[:space:]]done=[0-9]+$ ]] \
    || fail "the proofs row must keep the gate's scripts run, failed on the first run and seconds: $(tail -n 1 "$HOME_D/data/trunk-landing-proofs.tsv")"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" != "$(tip)" ] || fail "a landing that set only the tip's own red aside still does not move the green pin"
  [ "$(grep -c '^update ticket-red ' "$W/backlog-calls")" = 1 ] && [ "$(grep -c 'alert-line-red--proj-tip-' "$HOME_D/state/.wake-queue")" = 1 ] || fail "the same tip tree is not reported twice"
  pass 'the full gate blocks only what the lane broke: new, worse and broken-passing scripts block; the tip'"'"'s own red lands, reported once'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_flaky_failure_gets_one_rerun_before_it_is_judged() {
  local out
  world flaky; rig; seed_red_tip
  # Fails the first time the gate runs it and passes the second: judged flaky, so the lane lands beside the tip's own red.
  lane once "[ -e $W/seen ] || { : > $W/seen; echo 'not ok - flaky case' >&2; exit 1; }; exit 0" t/f.test.sh
  out=$(trunk land once 2>&1) || fail "a failure that passes on its one rerun must not block: $out"
  assert_contains "$out" "judged flaky" "the landing must say it set a flaky failure aside"
  assert_contains "$out" "gate=full-tip-red" "the tip's own red is still set aside and recorded"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" != "$(tip)" ] || fail "a landing whose gate passed on its one rerun does not move the green pin"
  assert_contains "$(grep '^add flaky-proj-f ' "$W/backlog-calls")" "[blocker] flaky test t/f.test.sh" "the flaky test is filed as its own fix row"
  assert_contains "$(cat "$HOME_D/data/trunk/flaky-proj.tsv")" "t/f.test.sh" "the flaky test is recorded"
  # The same script failing on both runs is the lane's own failure.
  lane twice 'echo "not ok - solid case" >&2; exit 1' t/g.test.sh
  refused 'a failure that repeats on the rerun' twice 't/g.test.sh'
  pass 'a failure gets one rerun before it is judged: a flaky one is set aside and filed as its own row, a repeated one blocks'
}

# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_lane_is_charged_only_for_a_script_the_parent_passes_three_times_of_three() {
  local out
  world rate; rig
  git -C "$PROJ" worktree add -q -b seed "$W/seed" trunk
  # The script fails with the lane's marker file; with no marker it fails on its 2nd and 5th run, by a counter outside the clone.
  commit_in "$W/seed" t/k.test.sh '[ -e t/mark ] && { echo "not ok - lane case" >&2; exit 1; }; n=$(cat '"$W"'/k-runs 2>/dev/null || echo 0); echo $((n + 1)) > '"$W"'/k-runs; case $((n + 1)) in 2|5) echo "not ok - flaky case" >&2; exit 1 ;; esac; exit 0' "seed k"
  commit_in "$W/seed" t/m.test.sh '[ -e t/mark2 ] && { echo "not ok - lane case" >&2; exit 1; }; exit 0' "seed m"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/seed" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
  # The parent fails 2 of 6 runs: the script fails by itself, so the lane lands and the script is filed once as flaky.
  lane rated on t/mark
  out=$(trunk land rated 2>&1) || fail "a script that fails by itself on the parent must not be charged to the lane: $out"
  assert_contains "$out" "fails by itself on the parent" "the landing must say it set a flaky parent script aside"
  assert_contains "$(cat "$HOME_D/data/trunk/flaky-proj.tsv")" "t/k.test.sh" "the flaky script is recorded"
  [ "$(grep -c '^add flaky-proj-' "$W/backlog-calls")" = 1 ] || fail "one flaky row is filed: $(cat "$W/backlog-calls")"
  # The parent passes 3 of 3: the same failure on the lane is the lane's own and is charged.
  lane charged on t/mark2
  refused 'a script the parent passes three times of three' charged 't/m.test.sh'
  pass 'a lane is charged only for a script its parent passes 3 of 3: one that fails by itself there lands with one flaky row'
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
  pass 'the landing gates are policy keys: the lint and tests cover the changed files, the whole suite is verify'"'"'s, run by hand only'
}

# shellcheck disable=SC2016 # the policy lines are written out verbatim and expand when the gate runs them
test_a_project_that_is_not_juggernaut_never_runs_juggernauts_gates() {
  local out rc=0 sha lib="$ROOT/bin/jg-trunk-policy-lib.sh"
  world foreign
  printf 'landing-gate=tests\n' > "$HOME_D/config/trunk-policy"  # no gate override: the built-in defaults decide, and they are Juggernaut's own suite
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
  printf 'gate-full@proj=test ! -e BAD\nlanding-gate=tests\n' > "$HOME_D/config/trunk-policy"
  out=$(bash -c ". '$lib'; JG_CONFIG_OVERRIDE='$HOME_D/config' jg_trunk_gate gate-verify proj '$PROJ' trunk")
  [ "$out" = 'test ! -e BAD' ] || fail "a project with only gate-full@proj must verify with it, got '$out'"
  printf 'gate-full@proj=true\ngate-verify@proj=false\nlanding-gate=tests\n' > "$HOME_D/config/trunk-policy"
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
  local part out id=1 before head
  world proofgate
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  lane ok one a.txt
  out=$(done_gate ok) || fail "a done with complete matching-head proof must be accepted: $out"
  trunk proof ok >/dev/null 2>&1 || fail "the landing pre-check must accept complete matching-head proof"
  lane p1 v1 f1.txt
  # (broken <part>, how it is broken, what the refusal must name)
  for part in receipt-absent:'completion receipt' receipt-fail:'completion receipt' receipt-stale:'completion receipt' \
              card-absent:'no approved merge-card evidence' card-stale:'no approved merge-card evidence' card-failed:'no approved merge-card evidence' \
              card-uncited:'no approved merge-card evidence' seal-absent:'no sealed done-done run' seal-stale:'no sealed done-done run' seal-dirty:'no sealed done-done run'; do
    prove "p$id"
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
  lane p2 v2 f2.txt; prove_part p2 receipt FAIL
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
test_three_lanes_land_in_order_a_red_one_is_refused_and_no_whole_suite_runs_per_landing() {
  local base rc out sha n
  world journey; rig; base=$(tip)
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  # The landing gate is the fast check (work.txt). The whole suite is red the way trunk-v3 was at 9f5bbb3af0d1: every script
  # passed and one shard ran over its wall-clock budget. A landing never runs it, so it never stops the next landing.
  printf '#!/usr/bin/env bash\necho run >> %s/suite-runs\necho "JG_TEST_AGGREGATE lanes=8 total=220 failed=0"\necho "jg-test-run: wall-clock budget exceeded: 606087ms > 600000ms" >&2\nexit 1\n' "$W" > "$W/suite-timeout.sh"
  printf 'gate-full=! grep -q BAD work.txt\ngate-verify=bash %s/suite-timeout.sh\n' "$W" >> "$HOME_D/config/trunk-policy"
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
  # A landing moves no pin and runs no suite: the tick's verify does, one at a time, and a suite over its time budget moves nothing.
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$base" ] || fail "a landing must not move the green pin"
  # So the next lane lands in minutes, on its changed files' tests alone, whatever the verify of the tip before it does.
  lane j5 'exit 0' t/j5.test.sh
  JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D" >/dev/null
  for _ in $(seq 1 150); do git -C "$PROJ" log --format=%s trunk | grep -q "^ticket j5" && ! grep -qs '^running' "$HOME_D"/data/jg-trunk-landing/*.state && break; sleep 0.2; done
  git -C "$PROJ" log --format=%s trunk | grep -q "^ticket j5" || fail "the next lane must land while the whole suite would be red: $(JG_HOME="$HOME_D" bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$HOME_D")"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$base" ] || fail "the next landing leaves the green pin too"
  [ ! -e "$W/live-moves" ] || fail "nothing here may go live"
  pass 'three lanes land in order with no human step, the red lane is refused, and a landing moves no pin and runs no suite, so a red suite stops no landing'
}

# A whole-suite run asked for by hand (verify) still finds the commit that broke the suite and reverts it by itself, and takes the
# green pin back below it; so does a red whose revert cannot apply cleanly.
# shellcheck disable=SC2016 # the script bodies are written out verbatim and expand when the gate runs them
test_a_red_verify_finds_by_hand_is_reverted_and_takes_the_green_pin_back() {
  local rc out before c
  world handverify; rig
  printf 'gate-full=! grep -q BAD work.txt\ngate-verify=bash %s/rig.sh --all\n' "$W" >> "$HOME_D/config/trunk-policy"
  lane j5 'echo "not ok - j5 breaks the suite" >&2; exit 1' t/j5.test.sh; before=$(tip)
  trunk land j5 >/dev/null 2>&1 || fail "j5 passes the fast check and lands"; c=$(tip)
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$before" ] || fail "the landing leaves the green pin"
  tip > "$HOME_D/state/trunk-green-proj"  # fixture: a verify that ran before j5 judged the trunk green at j5 (it is the red the next verify finds)
  rc=0; out=$(trunk verify "$PROJ" "$c" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify must fail on a commit that breaks the whole suite: $out"
  git -C "$PROJ" log --format=%B trunk | grep -q "^reverts: $c" || fail "a red verify finds must be reverted by itself: $out"
  git -C "$PROJ" cat-file -e "trunk:t/j5.test.sh" 2>/dev/null && fail "the bad commit's change must be undone on the tip"
  git -C "$PROJ" log --format='%H %s' trunk | grep -q "ticket j5" || fail "the bad commit must stay in the history: the trunk only moves forward"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$before" ] || fail "the red commit must take the green pin back below it, so no home goes live on it"
  assert_contains "$(cat "$W/backlog-calls" 2>/dev/null)" "update j5 --body-file" "the lane's ticket is told"
  assert_contains "$(cat "$HOME_D/state/.wake-queue")" "went red after it landed and was reverted by itself" "Overwatch is told"
  # A revert that cannot apply cleanly raises one alert and takes the green pin back below the red commit, and the next lane lands.
  lane k1 'echo "not ok - k1 breaks the suite" >&2; exit 1' t/k1.test.sh; trunk land k1 >/dev/null 2>&1 || fail "k1 must land by hand"
  lane k2 'exit 0' t/k1.test.sh; git -C "$W/lanes/k2" reset -q --hard trunk; commit_in "$W/lanes/k2" t/k1.test.sh 'echo "not ok - k1 breaks the suite" >&2; echo more; exit 1' "ticket k2"; prove k2
  trunk land k2 >/dev/null 2>&1 || fail "k2 must land by hand"
  c=$(git -C "$PROJ" log --format=%H --grep='ticket k1' -n 1 trunk)
  tip > "$HOME_D/state/trunk-green-proj"  # fixture: a pin above k1, as a green CI result would leave it
  rc=0; out=$(JG_HOME="$HOME_D" trunk verify "$PROJ" "$c" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a red that cannot be reverted is not green: $out"
  assert_contains "$out" "could not be reverted by itself; landings go on, and live stays on the last green commit $(git -C "$PROJ" rev-parse --short=12 "$c^")" "the red must say it could not be undone and that landings go on"
  assert_contains "$(cat "$HOME_D/state/.wake-queue")" "could not be reverted by itself" "Overwatch is told once"
  [ ! -e "$HOME_D/state/trunk-red-proj" ] || fail "a red never writes a red pin"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(git -C "$PROJ" rev-parse "$c^")" ] || fail "a red that cannot be undone must take the green pin back below the red commit"
  assert_contains "$(cat "$HOME_D/data/trunk-ci.tsv")" "$c"$'\t' "the red that could not be reverted is recorded"
  lane k3 'exit 0' t/k3.test.sh; out=$(trunk land k3 2>&1) || fail "a red that could not be reverted never stops the next landing: $out"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(git -C "$PROJ" rev-parse "$c^")" ] || fail "a landing above an unreverted red leaves the green pin below it, so the red is never live"
  pass 'a red a hand-run verify finds is reverted by itself and takes the green pin back, and so does one that cannot be undone, which stops no landing'
}

# The stall of 10 Nov: the green pin had not moved for 6 hours while 9 commits landed above it, because only the whole suite run
# after a landing moved it, and that run judged every change since the release base, so it grew with each landing. One more lane
# lands through the real landing check: its own gate is the trunk's green, so the pin is its head, and the check it ran judged its
# own changed scripts alone, the same count as the first landing after the release base.
# shellcheck disable=SC2016 # the gate bodies are written out verbatim and expand when the gate runs them
test_a_green_pin_left_behind_moves_to_the_next_landing_and_the_landing_check_does_not_grow() {
  local base i head row first ran old out
  world stalepin; rig; base=$(tip)
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  # The landing gate judges the changed scripts (as the fast required set does); verify judges every change since the release base.
  printf 'gate-full=bash %s/rig.sh $(git diff --name-only HEAD^ -- t)
gate-verify=echo run >> %s/suite-runs; bash %s/rig.sh $(git diff --name-only HEAD^ -- t)
' "$W" "$W" "$W" >> "$HOME_D/config/trunk-policy"
  [ "$(awk -F'\t' '$1 == "proj" { b = $4 } END { print b }' "$HOME_D/data/trunk-versions.tsv")" = "$base" ] || fail "the trunk version records its release base"
  lane s1 'exit 0' t/s1.test.sh; trunk land s1 >/dev/null 2>&1 || fail "s1 must land"
  rm -f -- "$HOME_D/state/s1.meta"
  first=$(grep -P '^s1\t' "$HOME_D/data/trunk-landing-proofs.tsv" | tail -n 1)
  [[ $first =~ gate=ran:1, ]] || fail "the first landing after the release base runs its one changed script: $first"
  # Build the eight intervening real landings in two stacks; only the first and next landing's gate counts are compared here.
  for i in 2 3 4 5; do lane "s$i" 'exit 0' "t/s$i.test.sh"; done
  trunk land-batch s2 s3 s4 s5 >/dev/null 2>&1 || fail "s2 through s5 must land"
  for i in 2 3 4 5; do rm -f -- "$HOME_D/state/s$i.meta"; done
  for i in 6 7 8 9; do lane "s$i" 'exit 0' "t/s$i.test.sh"; done
  trunk land-batch s6 s7 s8 s9 >/dev/null 2>&1 || fail "s6 through s9 must land"
  for i in 6 7 8 9; do rm -f -- "$HOME_D/state/s$i.meta"; done
  # As on 10 Nov: the pin is still at the release base, 6 hours old, with 9 landings above it.
  old=$(( $(date +%s) - 6 * 3600 ))
  printf '%s\n' "$base" > "$HOME_D/state/trunk-green-proj"; touch -d "@$old" "$HOME_D/state/trunk-green-proj"
  awk -F'\t' -v OFS='\t' -v t="$old" '{ $4 = t } 1' "$HOME_D/data/trunk-landings.tsv" > "$W/landings" && cat "$W/landings" > "$HOME_D/data/trunk-landings.tsv"
  [ "$(git -C "$PROJ" rev-list --count "$base..trunk")" = 9 ] || fail "9 commits sit above the green pin"
  lane s10 'exit 0' t/s10.test.sh
  out=$(sweep)
  head=$(tip)
  [ "$(git -C "$PROJ" log -1 --format=%s "$head")" = "ticket s10" ] || fail "the next lane lands: $out $(cat "$HOME_D"/data/jg-trunk-landing/s10.*.log 2>&1)"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" != "$head" ] || fail "the landing itself must not move the green pin"
  # The tick's verify moves it, over every change since the pin, and the landing check does not grow with them.
  for _ in $(seq 1 150); do [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$head" ] && break; sweep >/dev/null; sleep 0.3; done
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$head" ] || fail "the tick's verify must move the green pin to the tip, not $(cut -c1-12 "$HOME_D/state/trunk-green-proj")"
  row=$(grep -P '^s10\t' "$HOME_D/data/trunk-landing-proofs.tsv" | tail -n 1)
  ran=${row##*gate=ran:}; ran=${ran%%,*}
  [ "$ran" = 1 ] || fail "the landing's check must judge its own changed script alone, not the $(( $(git -C "$PROJ" rev-list --count "$base..trunk") )) landings since the release base: $row"
  [ -e "$W/suite-runs" ] || fail "the verify, not the landing, ran the suite"
  ! compgen -G "$HOME_D/data/jg-trunk-landing/s10.*.verify.log" >/dev/null || fail "the landing writes no verify log"
  pass 'a green pin left 6 hours behind 9 landings moves to the next landing'"'"'s head, and the landing'"'"'s check does not grow with the landings since the release base'
}

# shellcheck disable=SC2016 # the policy line is written out verbatim and expands when the gate runs it
test_a_lane_proved_at_the_change_the_lander_lands_is_not_tested_again() {
  local out
  world once; local JG_TRUNK_SEALED_REUSE=1
  # The tests leave a mark each time the gate runs them; the lint still runs on every landing.
  printf 'gate-full=echo ran >> %s/gate-runs; ! grep -q BAD work.txt\ngate-lint=echo linted >> %s/lint-runs; ! grep -q UGLY work.txt\nlanding-gate=tests\n' "$W" "$W" > "$HOME_D/config/trunk-policy"
  lane s1 one a.txt; lane s2 two b.txt
  # The trunk has not moved since s1 was proved and sealed: its sealed run is for the tree the lander would test.
  out=$(trunk land s1 2>&1) || fail "a lane proved at the tip's tree must land: $out"
  [ ! -e "$W/gate-runs" ] || fail "the tests must not run again for a tree the sealed run already passed"
  [ "$(grep -c . "$W/lint-runs")" = 1 ] || fail "the lint must still run for the landing"
  assert_contains "$out" "gate=sealed-run" "the landing must say the sealed run stood for the tests"
  # The trunk moved under s2: the lander rebases it onto a tree its run never saw, but the rebase leaves the patch as it was, so the run stands.
  out=$(trunk land s2 2>&1) || fail "a lane on a moved trunk must land: $out"
  [ ! -e "$W/gate-runs" ] || fail "the tests must not run for a rebase with the same change"
  assert_contains "$out" "gate=sealed-run" "a rebase with the same change keeps the sealed run"
  pass 'a lane whose sealed run is for the change the lander lands lands on the lint alone, also after a rebase with no change'
}

# A landing writes its latency row at once, from the done epoch it recorded while the lane's status file still existed.
test_every_landing_writes_its_latency_row_from_the_done_epoch_it_recorded() {
  local out done_at
  world latency
  lane lat1 one a.txt
  done_at=$(sed -n 's/^done \[at=\([0-9]*\)\].*/\1/p' "$HOME_D/state/lat1.status" | tail -n 1)
  out=$(trunk land lat1 2>&1) || fail "the lane must land: $out"
  rm -f "$HOME_D/state/lat1.status"   # cleanup removes the status file; no chat line exists in this home
  assert_contains "$(tail -n 1 "$HOME_D/data/trunk-landing-proofs.tsv")" "done=$done_at" "the landing must record the lane's done epoch"
  [ -s "$HOME_D/data/trunk-latency.tsv" ] || fail "the landing must write data/trunk-latency.tsv itself, with no watcher: $out"
  [ "$(awk -F'\t' '$1 == "lat1" { print $5 }' "$HOME_D/data/trunk-latency.tsv")" = "$done_at" ] \
    || fail "the latency row must carry the recorded done epoch $done_at: $(cat "$HOME_D/data/trunk-latency.tsv")"
  [ -n "$(awk -F'\t' '$1 == "lat1" { print $9 }' "$HOME_D/data/trunk-latency.tsv")" ] || fail "the latency row must hold its minutes"
  pass 'a landing records the lane done epoch and writes its latency row at once, with the status file gone'
}

# The real landing check bounds lint and tests by one shared deadline, and a timeout is retried rather than blamed on the lane.
test_landing_deadline_spans_both_gates() {
  local head before state
  world deadline
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  printf 'gate-lint=sleep 2\ngate-full=sleep 2\nlanding-gate=tests\nflush-at-ready=1\n' > "$HOME_D/config/trunk-policy"
  lane limit one work.txt
  before=$(tip); head=$(git -C "$PROJ" rev-parse fm/limit)
  JG_TEST_SEAM=1 JG_TRUNK_TEST_GATE_SECONDS=3 JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" \
    bash "$ROOT/core/trunk-landing/trunk-landing.sh" run "$HOME_D" limit "$head" >/dev/null
  state=$(cat "$HOME_D/data/jg-trunk-landing/limit.$head.state")
  [ "$(tip)" = "$before" ] || fail "a landing that exceeds the shared deadline must not move the trunk"
  assert_contains "$state" 'deadline' "the check must report the deadline"
  [[ $state = "retry 1 "* ]] || fail "a timeout must retry rather than blame the lane: $state"
  pass 'the landing check bounds lint and tests by one shared deadline'
}

# jg-i1iv3: a design task's first-draft receipt binds the head the lane proved; the trunk moving under it must not refuse the landing.
test_a_design_lane_lands_after_the_trunk_moved_on_the_receipt_it_proved() {
  local out id=dz1 h
  world designmoved
  lane dz0 other other.txt; lane "$id" design d.txt
  printf 'design_call=yes\n' >> "$HOME_D/state/$id.meta"
  printf '{"made":{"files":[{"file":"d.html"}]}}\n' > "$HOME_D/data/$id-fd-run.json"
  h=$(git -C "$PROJ" rev-parse "fm/$id")
  jq -n --arg t "$id" --arg h "$h" --arg e "done-done run: ok
first-draft receipt: $HOME_D/data/$id-fd-run.json" '{schema:1,task:$t,mode:"local-trunk",spawn_gen:("g-"+$t),head:$h,pr:"",verdict:"PASS",at:1,evidence:$e}' > "$HOME_D/state/$id.run-receipt.json"
  # The trunk moves under the proved lane, so the lander lands a rebased candidate that is not the receipt's head.
  trunk land dz0 >/dev/null 2>&1 || fail "dz0 must land first"
  out=$(trunk land "$id" 2>&1) || fail "a design lane proved at ${h:0:12} must land on the moved trunk: $out"
  [ "$(git -C "$PROJ" rev-parse "$(tip)^")" != "$h" ] || fail "the lane must have landed rebased"
  git -C "$PROJ" cat-file -e "trunk:d.txt" || fail "the landed tip must hold the design lane's file"
  # A design lane with no first-draft line is still refused at its proved head.
  lane dz2 design e.txt; printf 'design_call=yes\n' >> "$HOME_D/state/dz2.meta"
  lane dz3 other f.txt; trunk land dz3 >/dev/null 2>&1 || fail "dz3 must land"
  assert_contains "$(trunk land dz2 2>&1)" "no 'first-draft receipt" 'a design lane without the receipt line is still refused'
  pass 'a design lane lands on a moved trunk on the receipt it proved, and one without the receipt line is still refused'
}

# jg8-lander-receipt-line: a refusal the lander remembers as final is judged again once the lander itself is fixed. A design lane whose
# receipt holds the first-draft line was refused by a lander that misread the line; the lane's head did not change, so the remembered
# refusal was printed for ever after the fix.
test_a_design_lane_refused_by_a_broken_lander_lands_after_the_lander_is_fixed() {
  local id=dl1 h lib out
  world lander
  lane "$id" design d.txt
  printf 'design_call=yes\n' >> "$HOME_D/state/$id.meta"
  printf '{"made":{"files":[{"file":"d.html"}]}}\n' > "$HOME_D/data/$id-fd-run.json"
  h=$(git -C "$PROJ" rev-parse "fm/$id")
  jq -n --arg t "$id" --arg h "$h" --arg e "first-draft receipt: $HOME_D/data/$id-fd-run.json" \
    '{schema:1,task:$t,mode:"local-trunk",spawn_gen:("g-"+$t),head:$h,pr:"",verdict:"PASS",at:1,evidence:$e}' > "$HOME_D/state/$id.run-receipt.json"
  # The broken lander reads the line under another label, so it finds none.
  lib=$W/root/bin/jg-merge-gate-lib.sh
  sed -i "s/^JG_DESIGN_RECEIPT_LABEL='first-draft receipt'/JG_DESIGN_RECEIPT_LABEL='first-draft recept'/" "$lib"
  out=$(trunk land "$id" 2>&1) && fail "the broken lander must refuse $id"
  assert_contains "$out" "no 'first-draft receipt: <ref>' evidence line" 'the broken lander refuses a receipt that holds the line'
  # The refusal is final and remembered for this head; the same lander refuses again without a new run.
  out=$(trunk land "$id" 2>&1) && fail "the same broken lander must still refuse $id"
  # The fix reaches the lander; the head, the receipt and the task are unchanged.
  sed -i "s/^JG_DESIGN_RECEIPT_LABEL='first-draft recept'/JG_DESIGN_RECEIPT_LABEL='first-draft receipt'/" "$lib"
  out=$(trunk land "$id" 2>&1) || fail "a design lane whose receipt holds the line must land once the lander is fixed: $out"
  git -C "$PROJ" cat-file -e "trunk:d.txt" || fail "the landed tip must hold the design lane's file"
  # A design lane whose receipt holds no line is still refused by the fixed lander.
  lane dl2 design e.txt; printf 'design_call=yes\n' >> "$HOME_D/state/dl2.meta"
  assert_contains "$(trunk land dl2 2>&1)" "no 'first-draft receipt" 'a design lane without the line is refused'
  pass 'a refusal remembered under a broken lander is judged again after the fix, and a lane without the line stays refused'
}

# jg8-lander-receipt-line: a hand-roll approval written after the lander refused a small UI change is read by the next landing of the same head.
test_a_hand_roll_approval_written_after_a_refusal_is_read_by_the_next_landing() {
  local id=hr1 out
  world handroll
  git -C "$PROJ" worktree add -q -b uiseed "$W/uiseed" trunk
  commit_in "$W/uiseed" page.css 'a { color: red; }' "seed css"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/uiseed" rev-parse HEAD)"
  git -C "$PROJ" rev-parse trunk > "$HOME_D/state/trunk-tip-proj"
  lane "$id" 'a { color: blue; }' page.css
  printf 'design_call=no\nbase_branch=trunk\n' >> "$HOME_D/state/$id.meta"
  refused 'a small UI change with no hand-roll approval' "$id" 'no hand-roll approval'
  mkdir -p "$HOME_D/state/design-approvals"
  jq -n --arg id "$id" '{schema:1,task:$id,by:"main"}' > "$HOME_D/state/design-approvals/$id.handroll.json"
  out=$(trunk land "$id" 2>&1) || fail "the approved hand-roll must land on the next landing of the same head: $out"
  pass 'a hand-roll approval written after a refusal is read by the next landing of the same head'
}

# jg8-nav-gate-local-lane: a local lane has no PR body, so the nav gate reads its commit message, then its receipt evidence or done line.
test_a_ui_lane_states_its_nav_lines_in_the_commit_message_the_receipt_or_the_done_line() {
  local out id h
  world nav
  # No lines anywhere: refused, and the refusal names the commit message, never a PR body.
  lane nv1 ui a.txt; printf 'ui_change=yes\n' >> "$HOME_D/state/nv1.meta"
  refused 'a ui lane with no nav lines' nv1 "its commit message has no 'Nav before"
  assert_not_contains "$(trunk land nv1 2>&1 || true)" "PR body" "a local landing must not name a PR body"
  # The lines in the commit message: lands.
  lane nv2 ui b.txt $'Nav before: Home, Inbox\nNav after: Home, Inbox, Reports'; printf 'ui_change=yes\n' >> "$HOME_D/state/nv2.meta"
  out=$(trunk land nv2 2>&1) || fail "a ui lane with the lines in its commit message must land: $out"
  # The lines only in the completion receipt evidence: lands.
  lane nv3 ui c.txt; printf 'ui_change=yes\n' >> "$HOME_D/state/nv3.meta"
  h=$(git -C "$PROJ" rev-parse "fm/nv3")
  jq -n --arg t nv3 --arg h "$h" --arg e $'done-done run: ok\nNav before: Home\nNav after: Home, Reports' \
    '{schema:1,task:$t,mode:"local-trunk",spawn_gen:("g-"+$t),head:$h,pr:"",verdict:"PASS",at:1,evidence:$e}' > "$HOME_D/state/nv3.run-receipt.json"
  out=$(trunk land nv3 2>&1) || fail "a ui lane with the lines in its receipt must land: $out"
  # The lines only in the done line: lands.
  lane nv4 ui d.txt; printf 'ui_change=yes\n' >> "$HOME_D/state/nv4.meta"
  printf 'done [at=2000]: ready in branch fm/nv4 (local-trunk) Nav before: Home | Nav after: Home, Reports\n' >> "$HOME_D/state/nv4.status"
  out=$(trunk land nv4 2>&1) || fail "a ui lane with the lines in its done line must land: $out"
  # A dropped item is still refused on a local landing, from whichever place the lines come.
  lane nv5 ui e.txt $'Nav before: Home, Inbox\nNav after: Home'; printf 'ui_change=yes\n' >> "$HOME_D/state/nv5.meta"
  refused 'a ui lane that drops a nav item' nv5 "its commit message drops from Nav before (inbox)"
  pass 'a local ui lane names the commit message in the refusal and lands on its lines in the commit message, the receipt or the done line'
}

# A local lane lands with no tests at the landing (landing-gate=none, the default): the lint is the only check, the batch's verify is
# the one test run, and a red it finds is reverted. landing-gate=tests is the rollback: the changed files' tests run at the landing again.
test_a_local_lane_lands_with_no_tests_and_the_verify_reverts_a_red() {
  local rc out c before
  world nogate; rig
  printf 'gate-full=bash %s/rig.sh t/n1.test.sh\ngate-verify=bash %s/rig.sh --all\n' "$W" "$W" > "$HOME_D/config/trunk-policy"  # no landing-gate line: the default
  [ "$(pol landing-gate)" = none ] || fail "the landing runs no tests by default"
  lane n1 'echo "not ok - n1 breaks the suite" >&2; exit 1' t/n1.test.sh; before=$(tip)
  out=$(trunk land n1 2>&1) || fail "a lane whose test fails must land when no tests run at the landing: $out"
  assert_contains "$out" "gate=no-landing-gate" "the landing records that no test ran"
  [ "$(tip)" != "$before" ] || fail "the lane must be on the trunk"
  c=$(tip); printf '%s\n' "$before" > "$HOME_D/state/trunk-green-proj"
  rc=0; out=$(trunk verify "$PROJ" "$c" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the verify must find the red: $out"
  git -C "$PROJ" log --format=%B trunk | grep -q "^reverts: $c" || fail "the verify reverts the commit that caused the red: $out"
  # The rollback key puts the changed-tests gate back at the landing.
  printf 'landing-gate=tests\n' >> "$HOME_D/config/trunk-policy"
  lane n2 'echo "not ok - n1 breaks the suite" >&2; exit 1' t/n1.test.sh
  refused 'a landing with landing-gate=tests' n2 'gate'
  pass 'a local lane lands with no tests at the landing, the verify reverts its red, and landing-gate=tests is the rollback'
}

test_landing_deadline_spans_both_gates
test_the_full_gate_charges_a_lane_only_for_what_it_broke
test_every_landing_writes_its_latency_row_from_the_done_epoch_it_recorded
test_a_flaky_failure_gets_one_rerun_before_it_is_judged
test_a_lane_is_charged_only_for_a_script_the_parent_passes_three_times_of_three
test_a_tip_red_that_prints_its_elapsed_seconds_is_the_same_red_on_every_run
test_the_gates_are_policy_keys_with_fast_defaults
test_a_project_that_is_not_juggernaut_never_runs_juggernauts_gates
test_a_landing_rebases_the_lane_by_itself
test_done_and_landing_both_refuse_before_starting_on_any_missing_proof_input
test_a_proof_gap_names_the_reason_merge_card_refused_not_a_missing_run
test_the_check_starts_no_landing_until_the_whole_proof_is_there
test_three_lanes_land_in_order_a_red_one_is_refused_and_no_whole_suite_runs_per_landing
test_a_red_verify_finds_by_hand_is_reverted_and_takes_the_green_pin_back
test_a_green_pin_left_behind_moves_to_the_next_landing_and_the_landing_check_does_not_grow
test_a_lane_proved_at_the_change_the_lander_lands_is_not_tested_again
test_a_design_lane_lands_after_the_trunk_moved_on_the_receipt_it_proved
test_a_design_lane_refused_by_a_broken_lander_lands_after_the_lander_is_fixed
test_a_hand_roll_approval_written_after_a_refusal_is_read_by_the_next_landing
test_a_ui_lane_states_its_nav_lines_in_the_commit_message_the_receipt_or_the_done_line
test_a_local_lane_lands_with_no_tests_and_the_verify_reverts_a_red
printf 'jg-trunk-gate: ok\n'
