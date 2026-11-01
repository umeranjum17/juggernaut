#!/usr/bin/env bash
# The fixed-means-live rule, built from the real failure: a merged but
# unreleased fix was reported to the captain as fixed.
# The claim is refused-or-downgraded here, and a claim that carries a released
# ref and where it is observable passes, decided from the claim's words and the
# release record alone.
# The last two cases drive the real report helper so the rule is proven on a
# path a lead actually reports through, not only on the check itself.
# This is also the test that owns journeys/live-services.sh (the done-done journey runs this file),
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
for svc in nats dapr ntfy deliver; do
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
  assert_equals "merged-not-released: $claim" "$OUT" 'the downgraded report says merged-not-released'
  assert_contains "$ERR" 'merged-not-released' 'the reporter is told the new state'
  assert_contains "$ERR" 'release it' 'the reporter is told the next step'
  pass 'a merged-only fix claim is downgraded to merged-not-released'
}

test_an_unknown_release_state_downgrades() {
  local dir claim='Fixed the loop; live: v9.9.9 @ https://app.test/settings'
  dir=$(home unknown-release 'v1.0.0 2026-11-01T10:00Z app.test')
  expect_verdict 3 "$dir" 'done' "$claim" 'a ref the release record does not name is downgraded'
  assert_equals "merged-not-released: $claim" "$OUT" 'an unproven live clause is downgraded'
}

test_a_released_fix_with_an_observation_point_passes() {
  local dir claim='Fixed the loop; live: v9.9.9 @ https://app.test/settings (checked 12:04Z)'
  dir=$(home released 'v9.9.9 2026-11-01T10:00Z app.test')
  OUT=$(JG_HOME=$dir bash "$CHECK" 'done' "$claim" 2>"$dir/stderr")
  RC=$?
  [ "$RC" -eq 0 ] || fail "a released fix with an observation point must pass, got $RC"
  assert_equals "$claim" "$OUT" 'the proven claim is kept as written'
  pass 'a released ref and where it is observable passes'
}

test_a_recorded_commit_prefix_passes() {
  local dir claim='Fixed the loop; live: 4f2c9ab @ https://app.test/settings'
  dir=$(home commit '4f2c9abd0e1 2026-11-01T11:00Z app.test')
  expect_verdict 0 "$dir" 'done' "$claim" 'a recorded commit id matches a shorter claimed id'
}

test_a_claim_that_states_the_truth_passes() {
  local dir claim='Fixed the loop - merged-not-released: the PR merged, no release yet'
  dir=$(home stated)
  expect_verdict 0 "$dir" 'done' "$claim" 'a claim that says merged-not-released needs no live clause'
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
  local dir claim='Fixed the refresh bug; the PR is merged.'
  dir=$(home lead-report)
  mkdir -p "$dir/parent/state"
  printf 'umer\n' > "$dir/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$dir/parent" > "$dir/.jg-squad-lead-parent"
  JG_HOME=$dir bash "$REPORT" 'done' abcdef0123456789 "$claim" 2>"$dir/stderr" \
    || fail 'the lead report helper must still append a downgraded report'
  assert_contains "$(cat "$dir/parent/state/umer.status")" "merged-not-released: $claim" \
    'the parent channel carries merged-not-released, not an unavailable fix'
  pass 'the lead report path writes the downgrade'
}

test_the_lead_report_path_keeps_a_live_claim() {
  local dir claim='Fixed the refresh bug; live: v1.2.3 @ https://app.test/settings'
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
  local dir claim='Fixed it; live: v1.2.3 @ https://app.test' out rc=0
  dir=$(home down-service 'v1.2.3 2026-11-01T09:00Z app.test')
  mv "$PROBES/dapr" "$PROBES/dapr.off"; rm -f "$PROBES/ntfy"
  out=$(bash "$LIVE_SERVICES" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "the service check must exit 1 with services down, got $rc"
  assert_contains "$out" 'UP nats pid 4242' 'a running service prints its pid'
  assert_contains "$out" 'DOWN dapr' 'a stopped service is named'
  assert_contains "$out" 'LIVE_SERVICES: DOWN dapr ntfy' 'the verdict lists every down service'
  assert_contains "$out" 'NOT-IN-DESIGN wake-engine' 'the output says which services are not part of the design'
  assert_contains "$out" 'NOT-IN-DESIGN router' 'the router is named as not in the design'
  verdict "$dir" 'done' "$claim"
  [ "$RC" -eq 3 ] || fail "a recorded release with services down must not stand, got $RC"
  assert_equals "merged-not-released: $claim" "$OUT" 'the claim is rewritten as merged-not-released'
  assert_contains "$ERR" 'LIVE_SERVICES: DOWN dapr ntfy' 'the refusal names the down services'
  mv "$PROBES/dapr.off" "$PROBES/dapr"; printf '#!/bin/sh\necho "pid 4242"\n' > "$PROBES/ntfy"; chmod +x "$PROBES/ntfy"
  verdict "$dir" 'done' "$claim"
  [ "$RC" -eq 0 ] || fail "with every service up the live claim must stand, got $RC: $ERR"
  pass 'a live claim is refused while a required service is down and stands when all run'
}

test_a_merged_only_fix_is_downgraded
test_a_down_service_refuses_the_live_claim
test_an_unknown_release_state_downgrades
test_a_released_fix_with_an_observation_point_passes
test_a_recorded_commit_prefix_passes
test_a_claim_that_states_the_truth_passes
test_a_screen_free_change_passes
test_an_ordinary_report_is_untouched
test_the_lead_report_path_writes_the_downgrade
test_the_lead_report_path_keeps_a_live_claim
printf 'jg-live-claim: ok\n'
