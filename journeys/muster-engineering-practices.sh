#!/usr/bin/env bash
# Drive real Muster approval and plan verification against the help desk fixture.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../tests/lib.sh"

out=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
tmp=$(jg_test_tmproot jg-muster-practices)
export JG_HOME=$tmp/home JG_STATE_OVERRIDE=$tmp/home/state JG_DATA_OVERRIDE=$tmp/home/data JG_CONFIG_OVERRIDE=$tmp/home/config
export HOME=$tmp/user TMPDIR=$tmp/tmp XDG_DATA_HOME=$tmp/xdg-data XDG_CONFIG_HOME=$tmp/xdg-config XDG_STATE_HOME=$tmp/xdg-state
export SIGN_OFF_HOME=$tmp/board SIGN_OFF_FILER=muster-test JG_CAPTAIN_CHANNEL=$tmp/channel-off
export JG_BUS_HOMES=$tmp/bus-homes JG_VOICE_REWRITE_CMD=false
unset JG_ROOT_OVERRIDE JG_MUSTER_GATE
mkdir -p "$HOME" "$TMPDIR" "$JG_STATE_OVERRIDE" "$SIGN_OFF_HOME/.sign-off"
jg_test_beads_home "$JG_HOME"
printf '{"schema":2,"items":[]}\n' > "$SIGN_OFF_HOME/.sign-off/decisions.json"
printf 'leash: matters\n' > "$SIGN_OFF_HOME/.sign-off/config.yaml"
printf 'set mode off\n' > "$JG_CAPTAIN_CHANNEL"

ticket=jg-test-muster-practices
project=$tmp/helpdesk
cp -a "$ROOT/tests/fixtures/muster/example/helpdesk" "$project"
standards=$project/docs/ways-of-working.md
plan=$tmp/orders/plan.json
jg_test_add "$JG_HOME" "$ticket" '[feature] Verify help desk engineering practices'

approval() { "$ROOT/bin/jg-muster-approval.sh" "$@"; }
verify_plan() { "$ROOT/bin/jg" muster verify-plan "$ticket" "$plan"; }

approve_and_plan() {
  local sha ask gate
  sha=$(approval manifest "$ticket" "$project" --depth complete)
  ask=$(approval ask "$ticket" 'Help desk bot' "$sha")
  gate=$(sed -n 's/.*(gate \([^)]*\)).*/\1/p' <<< "$ask")
  [ -n "$gate" ] || fail "pack approval returned no question: $ask"
  printf '%s\tyes\tyes\n' "$gate" | "$ROOT/bin/jg-captain-hold.sh" answers --source 'Muster practice fixture' >/dev/null
  python3 -I "$ROOT/tests/fixtures/muster-acceptance/build.py" plan "$ticket" \
    "$JG_DATA_OVERRIDE/$ticket/muster/manifest-$sha.tsv" "$project/docs/charter.md" "$plan"
}

expect_open() {
  local practice=$1 result rc=0
  approve_and_plan
  result=$(verify_plan 2>&1) || rc=$?
  expect_code 1 "$rc" "plan with open $practice: $result"
  assert_contains "$result" "open engineering practices in docs/ways-of-working.md: $practice" "plan names $practice"
  printf '%s\n' "$result"
}

{
  cp "$standards" "$tmp/standards.md"
  sed 's/^| Observability | Accepted recommendation |/| Observability | Open |/' "$tmp/standards.md" > "$standards"
  expect_open Observability
  sed '/^| Security |/d' "$tmp/standards.md" > "$standards"
  expect_open Security

  cp "$tmp/standards.md" "$standards"
  approve_and_plan
  result=$(verify_plan)
  assert_contains "$result" 'plan ok:' 'the plan passes when all engineering practices are settled'
  printf '%s\n' "$result"
} 2>&1 | tee "$out/muster-engineering-practices.log"

jq -n --arg version "$(git -C "$ROOT" rev-parse HEAD)" --rawfile result "$out/muster-engineering-practices.log" '{
  target: {version: $version},
  start: "An isolated copy of the help desk fixture and a Muster ticket.",
  steps: ["Approve the pack with Observability open and verify its plan.",
          "Approve a version with the Security row missing and verify its plan.",
          "Restore all directions, approve the standards and verify the matching plan."],
  result: $result
}' > "$out/steps.json"
