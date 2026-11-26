#!/usr/bin/env bash
# Approve real fixture packs, then verify their catalogue against the submitted plan.
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot muster-use-cases)
export JG_HOME=$T/home JG_STATE_OVERRIDE=$T/home/state JG_DATA_OVERRIDE=$T/home/data JG_CONFIG_OVERRIDE=$T/home/config
export HOME=$T/user TMPDIR=$T/tmp XDG_CONFIG_HOME=$T/xdg-config XDG_DATA_HOME=$T/xdg-data XDG_STATE_HOME=$T/xdg-state
export SIGN_OFF_HOME=$T/board SIGN_OFF_FILER=muster-test JG_CAPTAIN_CHANNEL=$T/channel-off
unset JG_ROOT_OVERRIDE JG_MUSTER_GATE
mkdir -p "$HOME" "$TMPDIR" "$JG_STATE_OVERRIDE" "$SIGN_OFF_HOME/.sign-off"
printf '{"schema":2,"items":[]}\n' > "$SIGN_OFF_HOME/.sign-off/decisions.json"
printf 'leash: matters\n' > "$SIGN_OFF_HOME/.sign-off/config.yaml"
printf 'set mode off\n' > "$JG_CAPTAIN_CHANNEL"
jg_test_beads_home "$JG_HOME"

ticket=jg-test-muster-use-cases
project=$T/helpdesk
fixture=$ROOT/tests/fixtures/muster/example/helpdesk
cp -a "$fixture" "$project"
jg_test_add "$JG_HOME" "$ticket" '[feature] Check help desk use cases'
catalogue=$project/docs/use-cases.md
plan=$T/orders/plan.json

verify_plan() { "$ROOT/bin/jg" muster verify-plan "$ticket" "$plan"; }
approve_pack() {
  local result manifest ask gate
  result=$("$ROOT/bin/jg" muster approve manifest "$ticket" "$project" --depth complete) || fail "$result"
  manifest=$(jq -er '.data.stdout | rtrimstr("\n") | select(test("^[0-9a-f]{12}$"))' <<<"$result") ||
    fail "approval did not return a manifest id as text: $result"
  ask=$("$ROOT/bin/jg-muster-approval.sh" ask "$ticket" 'Help desk bot' "$manifest") || fail "$ask"
  gate=$(sed -n 's/.*(gate \([^)]*\)).*/\1/p' <<<"$ask")
  [ -n "$gate" ] || fail "approval did not return a question: $ask"
  printf '%s\tyes\tyes\n' "$gate" |
    "$ROOT/bin/jg-captain-hold.sh" answers --source 'Muster use cases board fixture' >/dev/null
  python3 -I "$ROOT/tests/fixtures/muster-acceptance/build.py" plan \
    "$ticket" "$JG_DATA_OVERRIDE/$ticket/muster/manifest-$manifest.tsv" "$project/docs/charter.md" "$plan"
}

refuse_catalogue() {
  local reason=$1 output rc=0
  approve_pack
  output=$(verify_plan 2>&1) || rc=$?
  expect_code 1 "$rc" "$output"
  assert_contains "$output" "$reason" "$reason"
  pass "$reason"
}

approve_pack
assert_contains "$(verify_plan)" 'plan ok:' 'the approved catalogue covers all journeys'
pass 'the approved catalogue covers all journeys'

sed "s/\`follow-up-question\`, //g" "$fixture/docs/use-cases.md" > "$catalogue"
refuse_catalogue 'journey follow-up-question has no use case'

sed "s/\`first-question-gets-answer\`, \`follow-up-question\`, \`answer-without-source-refused\`/none/" \
  "$fixture/docs/use-cases.md" > "$catalogue"
refuse_catalogue 'get-a-cited-answer has no journey'

sed "s/\`follow-up-question\`/\`invented-journey\`/" "$fixture/docs/use-cases.md" > "$catalogue"
refuse_catalogue 'get-a-cited-answer names unknown journey invented-journey'

sed "s/\`Handoff\`/\`Unknown object\`/" "$fixture/docs/use-cases.md" > "$catalogue"
refuse_catalogue 'get-agent-help names unknown domain object Unknown object'

rm "$catalogue"
refuse_catalogue 'docs/use-cases.md is missing from the approved pack'
