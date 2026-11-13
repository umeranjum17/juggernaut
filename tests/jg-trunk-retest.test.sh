#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh (the landing run state `retesting`, slice J32b) through its real `land` command and the landing
# check, with real git repositories and the real gate chain (tests/jg-trunk-fixture.sh). The resolver is a script of the home (policy
# conflict-resolver) and so is the retest runner (policy retest-runner); with none set the home runs `done-done verify --affected-by`.
#
# T1 After the resolution the run goes to `retesting`: the runner gets the touched files, only the journeys they affect run
#    (the count is printed and is smaller than the proof's), the receipt names the rebased commit and the receipt it extends, and the lane lands.
# T2 A resolution that breaks a journey ends the run `returned`: the trunk does not move and returned_at is written on the ticket.
# T3 A runner that stops on every try (three tries through the landing check) leaves the ticket in `delivering` with the wait `lead`, reason
#    `blocker`, and no steer, note or new agent goes to the worker.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# retester <name> <body>: the home's retest runner (policy retest-runner), run in a copy of the lander at the resolved commit.
retester() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$W/$1.sh"; chmod +x "$W/$1.sh"
  printf 'retest-runner=bash %s/%s.sh\n' "$W" "$1" >> "$HOME_D/config/trunk-policy"
}
# shellcheck disable=SC2016 # the resolver script expands its own variables
MERGE_ALL='while IFS= read -r f; do printf "merged\n" > "$f"; done < "$JG_RESOLVE_CONFLICTS"'

test_after_a_resolution_only_the_affected_journeys_run_and_the_receipt_extends_the_old_one() {
  local before out lane_head rows
  world retest
  resolver merge "$MERGE_ALL"
  # shellcheck disable=SC2016 # the runner script expands its own variables
  retester ok 'echo "journeys: 1 of 9"; printf "{\"commit\":\"%s\",\"extends\":\"%s\",\"files\":\"%s\",\"head\":\"%s\"}\n" "$JG_RETEST_COMMIT" "$JG_RETEST_EXTENDS" "$(paste -sd, "$JG_RETEST_FILES")" "$(git rev-parse HEAD)" > "$JG_HOME/retest-receipt.json"'
  conflicting_pair t
  lane_head=$(git -C "$PROJ" rev-parse fm/t-b); before=$(tip); out=$(trunk land t-b 2>&1) || fail "a resolved and retested conflict must land: $out"
  assert_contains "$out" 'retest: journeys: 1 of 9' 'the count of journeys that ran is printed'
  [ "$(jq -r .commit "$HOME_D/retest-receipt.json")" = "$(tip)" ] || fail "the receipt names the rebased commit that landed"
  [ "$(jq -r .head "$HOME_D/retest-receipt.json")" = "$(tip)" ] || fail "the runner ran at the rebased commit"
  [ "$(jq -r .extends "$HOME_D/retest-receipt.json")" = "$lane_head" ] || fail "the receipt names the receipt it extends"
  [ "$(jq -r .files "$HOME_D/retest-receipt.json")" = work.txt ] || fail "the runner is handed the touched files"
  rows=$(awk -F'\t' '$1 == "t-b" { print $5 }' "$HOME_D/data/trunk-landing-phases.tsv" | paste -sd' ' -)
  [ "$rows" = 'retesting checking' ] || fail "the run goes retesting and then checking: $rows"
  [ "$(git -C "$PROJ" rev-list --count "$before..trunk")" = 1 ] || fail "the lane lands as one commit"
  ! git -C "$PROJ" worktree list | grep -q retest- || fail "the lander's retest copy is removed again"
  pass 'after a resolution only the affected journeys run on the rebased commit, the receipt extends the old one, and the lane lands'
}

test_a_resolution_that_breaks_a_journey_ends_the_run_returned() {
  local before out
  world retest-red
  resolver merge "$MERGE_ALL"; retester red 'echo "journeys: 1 of 9"; echo "journey stage-words failed"; exit 1'
  conflicting_pair b
  before=$(tip); out=$(trunk land b-b 2>&1) && fail "a resolution that breaks a journey must not land: $out"
  assert_contains "$out" 'breaks a journey: journey stage-words failed' 'the refusal names the journey'
  printf '%s\n' "$out" > "$W/red.out"; [ "$(trunk classify "$W/red.out")" = final ] || fail "a red journey is the lane's: final"
  [ "$(tip)" = "$before" ] || fail "a returned run leaves the trunk alone"
  [ "$(awk -F'\t' '$1 == "b-b" { print $5 }' "$HOME_D/data/trunk-landing-phases.tsv" | paste -sd' ' -)" = 'retesting returned' ] || fail "the run ends returned"
  grep -q '^moment b-b returned_at' "$W/backlog-calls" || fail "returned_at puts the ticket back to building: $(cat "$W/backlog-calls")"
  pass 'a resolution that breaks a journey ends the run returned and gives the ticket back to building'
}

test_a_runner_that_stops_three_times_waits_for_the_lead_and_the_worker_is_not_told() {
  local c out _ m
  world retest-fault; m=$HOME_D/data/jg-trunk-landing
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/core" "$HOME_D/core"; ln -s "$ROOT/policy" "$HOME_D/policy"
  resolver merge "$MERGE_ALL"; retester dead 'echo "runner lost its model"; exit 3'
  conflicting_pair f; c=$(git -C "$PROJ" rev-parse fm/f-b)
  out=
  for _ in 1 2 3; do
    out="$out$(sweep)"; touch -d '3 minutes ago' "$m/f-b.$c.state"
  done
  out="$out$(sweep)"
  grep -q '^final gave up after 3 tries: REFUSED: the retest runner failed' "$m/f-b.$c.state" || fail "three runner faults end the check's tries: $(cat "$m/f-b.$c.state")"
  grep -q '^wait f-b lead blocker' "$W/backlog-calls" || fail "the ticket waits on the lead, reason blocker: $(cat "$W/backlog-calls")"
  [ "$(grep -c '^wait f-b' "$W/backlog-calls")" = 1 ] || fail "the wait is written once"
  [ ! -s "$W/send-calls" ] || fail "the worker is not told: $(cat "$W/send-calls")"
  ! grep -q '^moment f-b returned_at' "$W/backlog-calls" || fail "the ticket stays in delivering: no returned_at"
  [ "$(awk -F'\t' '$1 == "f-b" && $5 == "returned" { n++ } END { print n + 0 }' "$HOME_D/data/trunk-landing-phases.tsv")" = 0 ] || fail "a fault of the runner never returns the run"
  ! git -C "$PROJ" log --format=%s trunk | grep -qx 'ticket f-b' || fail "nothing landed"
  pass 'a runner that stops three times leaves the ticket in delivering on the wait lead (blocker) and the worker is not told'
}
test_after_a_resolution_only_the_affected_journeys_run_and_the_receipt_extends_the_old_one
test_a_resolution_that_breaks_a_journey_ends_the_run_returned
test_a_runner_that_stops_three_times_waits_for_the_lead_and_the_worker_is_not_told
printf 'jg-trunk-retest: ok\n'
