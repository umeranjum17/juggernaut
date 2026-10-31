#!/usr/bin/env bash
# The fixed-means-live rule, built from the real failure: a merged but
# unreleased fix was reported to the captain as fixed.
# The claim is refused-or-downgraded here, and a claim that carries a released
# ref and where it is observable passes, decided from the claim's words and the
# release record alone.
# The last two cases drive the real report helper so the rule is proven on a
# path a lead actually reports through, not only on the check itself.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/jg-live-claim.sh"
REPORT="$ROOT/bin/jg-squad-lead-report.sh"
WRITER="$ROOT/bin/jg-release-record.sh"
TMP_ROOT=$(jg_test_tmproot jg-live-claim)

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

# The record writer is what turns today's downgrade into a passing claim: it
# reads public release metadata, writes data/releases, and the same live claim
# then stands. Both exits are asserted, with no record and with one.
test_the_record_writer_makes_a_live_claim_pass() {
  local dir empty fb claim='fixed: live: 1.4.0 @ the dashboard'
  dir=$(home record-writer)
  empty=$(home record-writer-empty)
  fb=$(jg_fakebin "$dir")
  printf '%s\n' \
    '- app [direct-PR +yolo] - fixture app that ships to npm as app-axi (umeranjum17/app; npm app-axi) (fixture)' \
    '- releaseonly [direct-PR +yolo] - fixture project released by a forge tag (umeranjum17/releaseonly) (fixture)' \
    '- neverreleased [direct-PR +yolo] - fixture project with no release at all (umeranjum17/neverreleased) (fixture)' \
    > "$dir/data/projects.md"
  # Canned answers filtered through the caller's own --jq, so the writer's jq
  # filters run. The first release is a draft and must lose to the older tag.
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
path= filter=.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --method|-X) shift 2 ;;
    --jq) filter=$2; shift 2 ;;
    -f) shift 2 ;;
    *) path=$1; shift ;;
  esac
done
case "$path" in
  repos/*/neverreleased/releases) raw='[]' ;;
  */releases) raw='[{"tag_name":"v9.9.9","published_at":null},{"tag_name":"v2.0.0","published_at":"2026-10-20T08:00:00Z"}]' ;;
  search/issues) raw='{"total_count":7}' ;;
  *) raw='[]' ;;
esac
printf '%s' "$raw" | jq -r "$filter"
SH
  cat > "$fb/npm" <<'SH'
#!/usr/bin/env bash
# npm answers a one-item array here; the writer accepts both shapes.
printf '%s' '[{"version":"1.4.0","time":{"1.4.0":"2026-10-21T09:00:00.000Z"}}]'
SH
  chmod +x "$fb/gh" "$fb/npm"

  verdict "$empty" 'done' "$claim"
  assert_equals 3 "$RC" 'with no record the live claim is downgraded, as it is in every home today'

  PATH="$fb:$PATH" JG_HOME=$dir JG_DATA_OVERRIDE=$dir/data bash "$WRITER" \
    > "$dir/writer.out" 2>"$dir/stderr" \
    || fail "the record writer must succeed: $(cat "$dir/stderr")"
  OUT=$(cat "$dir/writer.out")
  assert_contains "$OUT" 'RELEASE: app 1.4.0 2026-10-21, 7 merges since' \
    'the npm version is the ref, with the merges since it'
  assert_contains "$OUT" 'RELEASE: releaseonly v2.0.0 2026-10-20, 7 merges since' \
    'the newest published forge tag is used, not the draft above it'
  assert_contains "$OUT" 'RELEASE: neverreleased no release recorded' \
    'a project that never released is said to have no release, never given a version'

  assert_grep '1.4.0 app 2026-10-21T09:00:00.000Z npm' "$dir/data/releases" \
    'the npm ref is written in the record format the live rule reads'
  assert_grep 'v2.0.0 releaseonly 2026-10-20T08:00:00Z forge-release' "$dir/data/releases" \
    'the forge release is written with its project and published date'
  assert_grep '# none neverreleased' "$dir/data/releases" \
    'a project with no release is recorded as none rather than given a version'

  verdict "$dir" 'done' "$claim"
  assert_equals 0 "$RC" 'with the writer record the same live claim stands'
  assert_equals "$claim" "$OUT" 'the passing claim is printed untouched'
  pass 'the record writer turns a downgraded live claim into a passing one'
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

test_a_merged_only_fix_is_downgraded
test_an_unknown_release_state_downgrades
test_a_released_fix_with_an_observation_point_passes
test_a_recorded_commit_prefix_passes
test_a_claim_that_states_the_truth_passes
test_a_screen_free_change_passes
test_an_ordinary_report_is_untouched
test_the_lead_report_path_writes_the_downgrade
test_the_lead_report_path_keeps_a_live_claim
test_the_record_writer_makes_a_live_claim_pass
printf 'jg-live-claim: ok\n'
