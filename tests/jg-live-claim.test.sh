#!/usr/bin/env bash
# The fixed-means-live rule, built from the real failure: a merged but
# unreleased fix was reported to the captain as fixed.
# The claim is refused-or-downgraded here, and a claim that carries a released
# ref and where it is observable passes, decided from the claim's words and the
# release record alone.
# The last two cases drive the real report helper so the rule is proven on a
# path a lead actually reports through, not only on the check itself.
# This is also the test that owns the live-services journey of .done-done.yaml (the done-done journey runs this file),
# so the changed-test map selects it for a change to that journey.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/jg-live-claim.sh"
REPORT="$ROOT/bin/jg-squad-lead-report.sh"
TMP_ROOT=$(jg_test_tmproot jg-live-claim)

# Fake service probes: every required service up, unless a case removes one.
PROBES="$TMP_ROOT/probes"
mkdir -p "$PROBES"
for svc in nats dapr; do
  printf '#!/bin/sh\necho "pid 4242"\n' > "$PROBES/$svc"; chmod +x "$PROBES/$svc"
done
export JG_LIVE_SERVICES_PROBES="$PROBES"
LIVE_SERVICES="$ROOT/bin/jg-live-services.sh"

# One home with an optional release record; every case reads its own.
home() {  # <name> [<release-record line>...]
  local name=$1 dir
  shift
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/data" "$dir/state"
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@" > "$dir/data/releases"; fi
  printf '%s\n' "$dir"
}

# Run the check in <home> and capture its stdout, stderr, and exit.
verdict() {  # <home> <verb> <claim>
  local dir=$1
  shift
  OUT=$(JG_HOME=$dir bash "$CHECK" "$@" 2>"$dir/stderr")
  RC=$?
  ERR=$(cat "$dir/stderr")
}

expect_verdict() {  # <expected-rc> <home> <verb> <claim> <label>
  local want=$1 label=$5
  verdict "$2" "$3" "$4"
  if [ "$RC" -ne "$want" ]; then
    printf 'expected exit %s, got %s for %s\nstdout: %s\nstderr: %s\n' \
      "$want" "$RC" "$label" "$OUT" "$ERR" >&2
    fail "$label"
  fi
  pass "$label"
}

test_a_merged_only_fix_is_downgraded() {
  local dir claim='Fixed the refresh bug; the PR is merged.'
  dir=$(home merged-only)
  OUT=$(JG_HOME=$dir bash "$CHECK" 'done' "$claim" 2>"$dir/stderr")
  RC=$?
  ERR=$(cat "$dir/stderr")
  [ "$RC" -eq 3 ] || fail "a merged-only fix claim must be downgraded (exit 3), got $RC"
  assert_equals "Landed, not in use: $claim" "$OUT" 'the downgraded report says merged-not-released'
  assert_contains "$ERR" 'Landed, not in use' 'the reporter is told the new state'
  assert_contains "$ERR" 'release it' 'the reporter is told the next step'
  pass 'a merged-only fix claim is downgraded to merged-not-released'
}

test_an_unknown_release_state_downgrades() {
  local dir claim='Fixed the loop; Released, v9.9.9; live: v9.9.9 @ https://app.test/settings'
  dir=$(home unknown-release 'v1.0.0 2026-11-01T10:00Z app.test')
  expect_verdict 3 "$dir" 'done' "$claim" 'a ref the release record does not name is downgraded'
  assert_equals "Landed, not in use: $claim" "$OUT" 'an unproven live clause is downgraded'
}

test_a_released_fix_with_an_observation_point_passes() {
  local dir claim='Fixed the loop; Released, v9.9.9; live: v9.9.9 @ https://app.test/settings (checked 12:04Z); carries: #12; waiting: none'
  dir=$(home released 'v9.9.9 2026-11-01T10:00Z app.test')
  OUT=$(JG_HOME=$dir bash "$CHECK" 'done' "$claim" 2>"$dir/stderr")
  RC=$?
  [ "$RC" -eq 0 ] || fail "a released fix with an observation point must pass, got $RC"
  assert_equals "$claim" "$OUT" 'the proven claim is kept as written'
  pass 'a released ref and where it is observable passes'
}

test_a_recorded_commit_prefix_passes() {
  local dir claim='Fixed the loop; Released, 4f2c9ab; live: 4f2c9ab @ https://app.test/settings; carries: #12; waiting: none'
  dir=$(home commit '4f2c9abd0e1 2026-11-01T11:00Z app.test')
  expect_verdict 0 "$dir" 'done' "$claim" 'a recorded commit id matches a shorter claimed id'
}

test_a_claim_that_states_the_truth_passes() {
  local dir claim='Fixed the loop - Landed, not in use: the PR merged, no release yet'
  dir=$(home stated)
  expect_verdict 0 "$dir" 'done' "$claim" 'a claim that says Landed, not in use needs no live clause'
}

test_a_screen_free_change_passes() {
  local dir claim='Fixed the lint rule that rejected long paths; screen: none'
  dir=$(home screen-free)
  expect_verdict 0 "$dir" 'done' "$claim" 'a change with no user-visible screen needs no live clause'
}

test_an_ordinary_report_is_untouched() {
  local dir claim='PR https://github.com/owner/repo/pull/12'
  dir=$(home ordinary)
  expect_verdict 0 "$dir" 'done' "$claim" 'a done report that claims no fix is untouched'
  expect_verdict 0 "$dir" working 'fixed the first failing case' 'a non-completion verb is untouched'
}

test_the_lead_report_path_writes_the_downgrade() {
  local dir claim='Fixed the refresh bug; the PR is merged. #tickets/jg-abc'
  dir=$(home lead-report)
  mkdir -p "$dir/parent/state"
  printf 'umer\n' > "$dir/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$dir/parent" > "$dir/.jg-squad-lead-parent"
  JG_HOME=$dir bash "$REPORT" 'done' abcdef0123456789 "$claim" 2>"$dir/stderr" \
    || fail 'the lead report helper must still append a downgraded report'
  assert_contains "$(cat "$dir/parent/state/umer.status")" "Landed, not in use: $claim" \
    'the parent channel carries merged-not-released, not an unavailable fix'
  pass 'the lead report path writes the downgrade'
}

test_the_lead_report_path_keeps_a_live_claim() {
  local dir claim='Fixed the refresh bug; Released, v1.2.3; live: v1.2.3 @ https://app.test/settings; carries: #12; waiting: none #tickets/jg-abc'
  dir=$(home lead-report-live 'v1.2.3 2026-11-01T09:00Z app.test')
  mkdir -p "$dir/parent/state"
  printf 'umer\n' > "$dir/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$dir/parent" > "$dir/.jg-squad-lead-parent"
  JG_HOME=$dir bash "$REPORT" 'done' abcdef0123456789 "$claim" 2>"$dir/stderr" \
    || fail 'the lead report helper must append a proven live claim'
  assert_contains "$(cat "$dir/parent/state/umer.status")" "$claim" \
    'the parent channel carries the released ref and where it is observable'
  pass 'the lead report path keeps a live claim'
}

test_a_down_service_refuses_the_live_claim() {
  local dir claim='Fixed it; Released, v1.2.3; live: v1.2.3 @ https://app.test; carries: #12; waiting: none' out rc=0
  dir=$(home down-service 'v1.2.3 2026-11-01T09:00Z app.test')
  mv "$PROBES/dapr" "$PROBES/dapr.off"; mv "$PROBES/nats" "$PROBES/nats.off"
  out=$(bash "$LIVE_SERVICES" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "the service check must exit 1 with services down, got $rc"
  assert_contains "$out" 'DOWN nats' 'a stopped service is named'
  assert_contains "$out" 'DOWN dapr' 'every stopped service is named'
  assert_contains "$out" 'LIVE_SERVICES: DOWN nats dapr' 'the verdict lists every down service'
  assert_contains "$out" 'NOT-IN-DESIGN wake-engine' 'the output says which services are not part of the design'
  assert_contains "$out" 'NOT-IN-DESIGN router' 'the router is named as not in the design'
  verdict "$dir" 'done' "$claim"
  [ "$RC" -eq 3 ] || fail "a recorded release with services down must not stand, got $RC"
  assert_equals "Landed, not in use: $claim" "$OUT" 'the claim is rewritten as merged-not-released'
  assert_contains "$ERR" 'LIVE_SERVICES: DOWN nats dapr' 'the refusal names the down services'
  mv "$PROBES/dapr.off" "$PROBES/dapr"; mv "$PROBES/nats.off" "$PROBES/nats"
  verdict "$dir" 'done' "$claim"
  [ "$RC" -eq 0 ] || fail "with every service up the live claim must stand, got $RC: $ERR"
  pass 'a live claim is refused while a required service is down and stands when all run'
}

# Add a task record <id> to <home>, optionally with a merge-notified marker.
task() {  # <home> <id> <pr-number> [merged]
  printf 'kind=ship\npr=https://github.com/o/r/pull/%s\n' "$3" > "$1/state/$2.meta"
  if [ "${4:-}" = merged ]; then : > "$1/state/$2.pr-poll-merge-notified"; fi
}

test_a_landed_change_is_live_where_the_homes_run_it() {
  local dir lead claim sha
  dir=$(home homes-run); lead="$TMP_ROOT/homes-run-lead"
  g() { git -c user.email=t@t -c user.name=t "$@"; }
  g init -q "$dir" && g -C "$dir" commit -q --allow-empty -m 'base'
  g -C "$dir" tag c-1
  g -C "$dir" commit -q --allow-empty -m 'jg8-slice: the slice' -m 'Ticket: jg8-slice'
  sha=$(git -C "$dir" rev-parse HEAD)
  git clone -q "$dir" "$lead"
  mkdir -p "$dir/data"
  printf -- '- lead1 - test lead (home: %s; scope: all; projects: juggernaut; added 2026-11-13)\n' "$lead" > "$dir/data/squad_leads.md"
  claim='Fixed the slice, ticket jg8-slice.'
  verdict "$dir" 'done' "$claim"
  [ "$RC" -eq 3 ] || fail "a change the homes run must extend the claim (exit 3), got $RC: $ERR"
  assert_contains "$OUT" 'In use, c-1-1-g' 'the claim carries the version'
  assert_contains "$OUT" ', homes lead1, primary' 'the claim names every home that runs it'
  assert_contains "$ERR" 'run it' 'the reporter is told why it is live'
  verdict "$dir" 'done' "Fixed it, commit ${sha:0:9}."
  assert_contains "$OUT" ', homes lead1, primary' 'a commit id names the change too'
  # A trunk commit that the lead does not run yet is named after not-yet-in.
  g -C "$dir" commit -q --allow-empty -m 'jg8-next: next' -m 'Ticket: jg8-next'
  verdict "$dir" 'done' 'Fixed the next one, jg8-next.'
  assert_contains "$OUT" ', homes primary; not yet in: lead1' 'a home behind the change is named'
  # A change no home runs stays merged-not-released.
  git -C "$dir" update-ref refs/heads/side "$(g -C "$dir" commit-tree -p "$sha" -m 'jg8-side: x' -m 'Ticket: jg8-side' 'HEAD^{tree}')"
  printf '%s\n' "$(git -C "$dir" rev-parse side)" > "$dir/state/trunk-tip-juggernaut"
  verdict "$dir" 'done' 'Fixed the side one, jg8-side.'
  assert_equals 'Landed, not in use: Fixed the side one, jg8-side.' "$OUT" 'a change no home runs stays merged-not-released'
  pass 'a landed change is live where the homes run it'
}

test_an_omitted_carries_and_waiting_clause_is_flagged_and_extended() {
  local dir claim='Fixed the loop; Released, v9.9.9; live: v9.9.9 @ https://app.test/settings'
  dir=$(home extended 'v8.0.0 2026-10-01T10:00Z app.test prs=3' 'v9.9.9 2026-11-01T10:00Z app.test prs=12,#15')
  task "$dir" open-a 20
  task "$dir" open-b 21
  task "$dir" open-dup 21
  task "$dir" merged-c 22 merged
  task "$dir" carried-d 15
  task "$dir" carried-old 3
  expect_verdict 3 "$dir" 'done' "$claim" 'a live claim that omits carries and waiting is flagged'
  assert_equals "$claim; carries: #12 #15; waiting: #20 #21" "$OUT" 'the claim is extended from the release and task records'
  assert_contains "$ERR" 'does not name the PRs release v9.9.9 carries' 'the missing carried list is named on stderr'
  assert_contains "$ERR" 'does not name the open PRs that wait' 'the missing waiting list is named on stderr'
}

test_one_omitted_clause_is_named_alone() {
  local dir
  dir=$(home one-omitted 'v9.9.9 2026-11-01T10:00Z app.test prs=12')
  expect_verdict 3 "$dir" 'done' 'Fixed it; Released, v9.9.9; live: v9.9.9 @ https://app.test; carries: #12' 'a claim that omits only waiting is flagged'
  assert_equals 'Fixed it; Released, v9.9.9; live: v9.9.9 @ https://app.test; carries: #12; waiting: none' "$OUT" 'only the waiting clause is added'
  case "$ERR" in *'carries (carries'*) fail 'the carried list was named although the claim has it' ;; esac
  expect_verdict 3 "$dir" 'done' 'Fixed it; Released, v9.9.9; live: v9.9.9 @ https://app.test; waiting: none' 'a claim that omits only carries is flagged'
  assert_equals 'Fixed it; Released, v9.9.9; live: v9.9.9 @ https://app.test; waiting: none; carries: #12' "$OUT" 'only the carries clause is added'
}

test_a_record_without_prs_reads_unrecorded() {
  local dir
  dir=$(home no-prs 'v9.9.9 2026-11-01T10:00Z app.test')
  expect_verdict 3 "$dir" 'done' 'Fixed it; Released, v9.9.9; live: v9.9.9 @ https://app.test; waiting: none' 'a release record with no prs= field is flagged'
  assert_contains "$OUT" 'carries: unrecorded' 'the extension says the carried PRs are unrecorded'
  assert_contains "$ERR" 'no prs= field' 'stderr names the missing record field'
}

test_the_lead_report_path_prints_the_extended_claim() {
  local dir claim='Fixed the refresh bug; Released, v1.2.3; live: v1.2.3 @ https://app.test/settings #tickets/jg-abc'
  dir=$(home lead-report-extended 'v1.2.3 2026-11-01T09:00Z app.test prs=40')
  task "$dir" waiting-e 41
  mkdir -p "$dir/parent/state"
  printf 'umer\n' > "$dir/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$dir/parent" > "$dir/.jg-squad-lead-parent"
  JG_HOME=$dir bash "$REPORT" 'done' abcdef0123456789 "$claim" 2>"$dir/stderr" \
    || fail 'the lead report helper must append the extended claim'
  assert_contains "$(cat "$dir/parent/state/umer.status")" "$claim; carries: #40; waiting: #41" \
    'the parent channel carries the extended live claim'
  pass 'the lead report path prints the extended claim'
}

test_a_merged_only_fix_is_downgraded
test_a_landed_change_is_live_where_the_homes_run_it
test_a_down_service_refuses_the_live_claim
test_an_unknown_release_state_downgrades
test_a_released_fix_with_an_observation_point_passes
test_a_recorded_commit_prefix_passes
test_a_claim_that_states_the_truth_passes
test_a_screen_free_change_passes
test_an_ordinary_report_is_untouched
test_the_lead_report_path_writes_the_downgrade
test_the_lead_report_path_keeps_a_live_claim
test_an_omitted_carries_and_waiting_clause_is_flagged_and_extended
test_one_omitted_clause_is_named_alone
test_a_record_without_prs_reads_unrecorded
test_the_lead_report_path_prints_the_extended_claim
if [ -n "${DONE_DONE_EVIDENCE_ROOT:-}" ]; then
  jq -n --arg v "$(git -C "$ROOT" describe --tags --always 2>/dev/null)" '{
    target: {version: $v},
    start: "a Main home and a registered lead home that both run a trunk commit carrying a Ticket trailer",
    steps: ["report done with a fix claim that names the landed ticket", "report done with a commit id", "advance Main past the lead and claim the newer ticket", "claim a ticket that no home runs"],
    result: "the claim gains live: <version> @ homes <ids> (with not yet in: for a lagging home), and a change no home runs stays merged-not-released"
  }' > "$DONE_DONE_EVIDENCE_ROOT/steps.json" || fail 'could not write the step record'
fi
printf 'jg-live-claim: ok\n'
