#!/usr/bin/env bash
# Drive a scripted requirements interview through the real Muster rounds and pack approval.
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for dependency in jq openssl python3 sign-off-axi; do
  command -v "$dependency" >/dev/null || { printf 'setup error: %s is required\n' "$dependency" >&2; exit 77; }
done

T=$(jg_test_tmproot jg-muster-requirements)
export JG_HOME=$T/home JG_STATE_OVERRIDE=$T/home/state JG_DATA_OVERRIDE=$T/home/data JG_CONFIG_OVERRIDE=$T/home/config
export HOME=$T/user TMPDIR=$T/tmp XDG_DATA_HOME=$T/xdg-data XDG_CONFIG_HOME=$T/xdg-config XDG_STATE_HOME=$T/xdg-state
export SIGN_OFF_HOME=$T/board SIGN_OFF_FILER=muster-test JG_CAPTAIN_CHANNEL=$T/channel-off
unset JG_ROOT_OVERRIDE JG_MUSTER_GATE
mkdir -p "$HOME" "$TMPDIR" "$JG_STATE_OVERRIDE" "$SIGN_OFF_HOME/.sign-off"
jg_test_beads_home "$JG_HOME"
printf '{"schema":2,"items":[]}\n' > "$SIGN_OFF_HOME/.sign-off/decisions.json"
printf 'leash: matters\n' > "$SIGN_OFF_HOME/.sign-off/config.yaml"
printf 'set mode off\n' > "$JG_CAPTAIN_CHANNEL"

test_ticket=jg-test-muster-requirements
project=$T/helpdesk
cp -a "$ROOT/tests/fixtures/muster/example/helpdesk" "$project"
vision=$project/docs/vision.md
spec=$project/docs/specs/helpdesk.md
jg_test_add "$JG_HOME" "$test_ticket" '[feature] Interview for help desk requirements'

muster() { "$ROOT/bin/jg-muster.sh" "$@"; }
approval() { "$ROOT/bin/jg-muster-approval.sh" "$@"; }
show_round() {
  jq -n --arg question "$2" --arg why "$3" --arg a "$4" --arg b "$5" '[{
    question: $question, why: $why,
    options: [{value: "a", label: $a, outcome: "The spec adopts " + $a},
              {value: "b", label: $b, outcome: "The spec adopts " + $b}],
    recommend: "a", recommend_reason: "It gives users a more predictable reply time."
  }]' > "$T/questions.json"
  muster round "$test_ticket" --questions "$T/questions.json" --round "$1" --doc "$vision"
}
reply() {
  local note
  note=$(printf '[chat telegram 42:%s]\n%s\n' "$1" "$2" |
    "$ROOT/bin/jg-inbox.sh" note --request-id "tg-42-$1" --json - | jq -er .id)
  muster answer "$test_ticket" --note "$note"
}

show_round 1 'What should users expect after sending a question?' \
  'The current spec says how the help desk answers, without a response time.' 'A quick reply' 'A reply later'
reply 101 'R1Q1 a'
assert_contains "$(cat "$vision")" 'R1Q1: "A quick reply"' 'the owner asks for a quick reply'

target='p95 at most 300 ms at 20 requests per second'
show_round 2 'How quickly should the help desk answer?' \
  'The first answer asks for a quick reply. The build needs a measurable target for a cited reply.' \
  "$target" 'p95 at most 800 ms at 20 requests per second'
muster round-status "$test_ticket" --json |
  jq -e '.rounds[] | select(.round == "2") | .complete == false and .questions[0].state == "open"' >/dev/null ||
  fail 'the unanswered performance question must keep the round open'
reply 102 'R2 yes to the rest'
muster round-status "$test_ticket" --json |
  jq -e '.rounds[] | select(.round == "2") | .complete and .questions[0].taken == "owner" and .questions[0].doc_written' >/dev/null ||
  fail 'the performance round did not close with the owner answer saved'
assert_contains "$(cat "$vision")" "R2Q1: \"$target\"" 'the numeric recommendation needs and gets an owner answer'

functional='| Journeys | Answered | The first answer cites a source. | vision.md | first-question-gets-answer |'
performance="| Performance | Accepted recommendation | $target | vision.md R2Q1 | Measure p95 for cited replies over 10 minutes. |"
exclusion='| Localisation | Out of scope | English only for the first charter. | First-charter scope | - |'
awk -v functional="$functional" -v performance="$performance" -v exclusion="$exclusion" '
  /^## Functional requirements$/ { section = "functional" }
  /^## Non-functional requirements$/ { section = "quality" }
  /^## Objectives/ { exit }
  section && /^\| <coverage category>/ {
    if (section == "functional") print functional
    else { print performance; print exclusion }
    next
  }
  section { print }
' "$ROOT/.agents/skills/muster/templates/spec.md" > "$T/requirements.md"
awk '/^## Objectives/ { while ((getline line < requirements) > 0) print line } { print }' \
  requirements="$T/requirements.md" "$spec" > "$T/spec.md"
mv "$T/spec.md" "$spec"

manifest=$(approval manifest "$test_ticket" "$project" --depth complete) || fail "$manifest"
ask=$(approval ask "$test_ticket" 'Help desk bot' "$manifest") || fail "$ask"
gate=$(sed -n 's/.*(gate \([^)]*\)).*/\1/p' <<<"$ask")
[ -n "$gate" ] || fail "the pack approval did not return a question: $ask"
printf '%s\tyes\tyes\n' "$gate" | "$ROOT/bin/jg-captain-hold.sh" answers --source 'Muster requirements board fixture' >/dev/null
assert_contains "$(approval verify "$test_ticket" "$project")" 'approved:' 'the pack with coverage is approved'
approved_spec=$JG_DATA_OVERRIDE/$test_ticket/muster/pack-$manifest/docs/specs/helpdesk.md
for row in "$functional" "$performance" "$exclusion"; do
  assert_contains "$(cat "$approved_spec")" "$row" 'the saved spec carries the settled requirement'
done

sed 's/p95 at most 300 ms/p95 at most 800 ms/' "$spec" > "$T/spec.md"
mv "$T/spec.md" "$spec"
if rejection=$(approval verify "$test_ticket" "$project" 2>&1); then fail 'changing the target kept its old approval'; fi
assert_contains "$rejection" 'a fresh approval is needed' 'the changed target needs a new approval'
pass 'a numeric follow-up and the other settled requirements reach the approved spec'
