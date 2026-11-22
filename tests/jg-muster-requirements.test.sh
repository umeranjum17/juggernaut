#!/usr/bin/env bash
# Drive a scripted requirements interview through Muster approval, plan verification and order freezing.
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
export JG_BUS_HOMES=$T/bus-homes JG_VOICE_REWRITE_CMD=false
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
sign_manifest() {
  local ask gate
  ask=$(approval ask "$test_ticket" 'Help desk bot' "$1") || fail "$ask"
  gate=$(sed -n 's/.*(gate \([^)]*\)).*/\1/p' <<<"$ask")
  [ -n "$gate" ] || fail "the pack approval did not return a question: $ask"
  printf '%s\tyes\tyes\n' "$gate" | "$ROOT/bin/jg-captain-hold.sh" answers --source 'Muster requirements board fixture' >/dev/null
}
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
awk -F '[|]' -v functional="$functional" -v performance="$performance" -v exclusion="$exclusion" '
  FILENAME == ARGV[1] {
    if (/^## /) section = ""
    if ($0 == "## Functional requirements") section = "functional"
    if ($0 == "## Non-functional requirements") section = "quality"
    if (section && /^\|/) {
      category = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", category)
      if (category == "" || category == "Category" || category ~ /^-+$/) next
      if (category == "Journeys") row = functional
      else if (category == "Performance") row = performance
      else if (category == "Localisation") row = exclusion
      else row = "| " category " | Out of scope | The first charter covers the cited reply and its response time. | First-charter scope | - |"
      rows[section, ++count[section]] = row
    }
    next
  }
  FNR == 1 {
    section = ""
    if (!count["functional"] || !count["quality"]) exit 1
  }
  /^## Functional requirements$/ { section = "functional" }
  /^## Non-functional requirements$/ { section = "quality" }
  /^## Objectives/ { exit }
  section && /^\| <coverage category>/ {
    for (i = 1; i <= count[section]; i++) print rows[section, i]
    next
  }
  section { print }
' "$ROOT/.agents/skills/muster/requirements.md" "$ROOT/.agents/skills/muster/templates/spec.md" > "$T/requirements.md" ||
  fail 'could not read both Muster coverage category tables'
awk '/^## Objectives/ { while ((getline line < requirements) > 0) print line } { print }' \
  requirements="$T/requirements.md" "$spec" > "$T/spec.md"
mv "$T/spec.md" "$spec"

manifest=$(approval manifest "$test_ticket" "$project" --depth complete) || fail "$manifest"
sign_manifest "$manifest"
assert_contains "$(approval verify "$test_ticket" "$project")" 'approved:' 'the pack with coverage is approved'
muster_dir=$JG_DATA_OVERRIDE/$test_ticket/muster
approved_spec=$muster_dir/pack-$manifest/docs/specs/helpdesk.md
for row in "$functional" "$performance" "$exclusion"; do
  assert_contains "$(cat "$approved_spec")" "$row" 'the saved spec carries the settled requirement'
done

sed 's/p95 at most 300 ms/p95 at most 800 ms/' "$spec" > "$T/spec.md"
mv "$T/spec.md" "$spec"
if rejection=$(approval verify "$test_ticket" "$project" 2>&1); then fail 'changing the target kept its old approval'; fi
printf '%s\n' "$rejection"
assert_contains "$rejection" 'a fresh approval is needed' 'the changed target needs a new approval'
pass 'a numeric follow-up and the other settled requirements reach the approved spec'

plan=$T/orders/plan.json
mkdir -p "$T/orders"
build_plan() {
  python3 -I "$ROOT/tests/fixtures/muster-acceptance/build.py" plan \
    "$test_ticket" "$muster_dir/manifest-$1.tsv" "$project/docs/charter.md" "$plan"
}

cp "$approved_spec" "$spec"
sed 's/^| Performance | Accepted recommendation |/| Performance | Open |/' "$spec" > "$T/spec.md"
mv "$T/spec.md" "$spec"
assert_contains "$(cat "$spec")" '| Performance | Open |' 'the fixture reopens Performance'
open_manifest=$(approval manifest "$test_ticket" "$project" --depth complete) || fail "$open_manifest"
sign_manifest "$open_manifest"
assert_contains "$(approval verify "$test_ticket" "$project")" 'approved:' 'the altered pack has its own approval'
build_plan "$open_manifest"
if plan_rejection=$("$ROOT/bin/jg" muster verify-plan "$test_ticket" "$plan" 2>&1); then
  fail 'plan verification accepted an open Performance requirement'
fi
printf '%s\n' "$plan_rejection"
assert_contains "$plan_rejection" 'open requirements categories: Performance' 'plan verification names the open Performance category'

cp "$approved_spec" "$spec"
restored_manifest=$(approval manifest "$test_ticket" "$project" --depth complete) || fail "$restored_manifest"
[ "$restored_manifest" = "$manifest" ] || fail 'the restored spec did not reproduce the original manifest'
sign_manifest "$manifest"
assert_contains "$(approval verify "$test_ticket" "$project")" 'approved:' 'the restored pack is approved'
build_plan "$manifest"

printf '%s\n' '- demo [local-trunk +yolo] - fixture (added 2026-11-22)' > "$JG_DATA_OVERRIDE/projects.md"
mkdir -p "$JG_HOME/projects"
ln -s "$project" "$JG_HOME/projects/demo"
export JG_PROJECTS_OVERRIDE="$JG_HOME/projects"
"$ROOT/bin/jg" muster depth record --ticket "$test_ticket" --depth complete --reason fixture

jq '.slices[].project = "demo" | .muster.decisions_and_assumptions = [{
  "id": "retention",
  "recommendation": "Keep chat logs for 30 days.",
  "status": "accepted recommendation",
  "override": null,
  "slices": ["c2"]
}]' "$plan" > "$T/plan.json"
mv "$T/plan.json" "$plan"
jq '.muster.decisions_and_assumptions[0].override = "Keep chat logs for 7 days."' "$plan" > "$T/plan.json"
mv "$T/plan.json" "$plan"

legacy_plan=$(approval verify-plan "$test_ticket" "$plan" --slice-directions 2>"$T/plan.stderr") ||
  fail "the legacy pack did not verify: $legacy_plan $(cat "$T/plan.stderr")"
jq -e '.plan_sha256 and (.directions | type == "object")' <<<"$legacy_plan" >/dev/null ||
  fail 'the legacy warning changed the plan JSON'
legacy_warning=$(cat "$T/plan.stderr")
assert_contains "$legacy_warning" 'docs/design/helpdesk.md is a legacy technical design; use docs/architecture/helpdesk.md' \
  'verify-plan names the migration on stderr'
printf 'Legacy plan verified. %s\n' "$legacy_warning"

plan_id=$(jq -er .plan "$plan") || fail 'the fixture plan has no id'
JG_SWARM_ARM_KICK=0 "$ROOT/bin/jg-swarm.sh" start "$plan" --harness codex --model gpt-6.2-sol --effort high --wait
frozen_plan=$JG_DATA_OVERRIDE/swarm/$plan_id/plan.json
c2_order=$(jq -er '
  [.slices[] | select(.id == "c2")] |
  if length == 1 then .[0].order_path | strings | select(length > 0)
  else error("expected one c2 slice") end
' "$frozen_plan") || fail 'the frozen plan must name one c2 order'
case $c2_order in
  /*) ;;
  *) c2_order=${frozen_plan%/*}/$c2_order ;;
esac
c2_text=$(cat "$c2_order") || fail 'could not read the frozen c2 order'
selected_line=$(grep -F -m 1 -- 'Keep chat logs for 7 days.' "$c2_order") || fail 'the frozen c2 order omits the seven-day override'
[[ $c2_text != *'30 days'* ]] || fail 'the frozen c2 order still contains the thirty-day recommendation'
printf '%s\n' "$selected_line"

other_orders=$(jq -er '
  .slices[] | select(.id != "c2") | .order_path |
  if type == "string" and length > 0 then . else error("missing order path") end
' "$frozen_plan") || fail 'the frozen plan must name the other slice orders'
while IFS= read -r order_path; do
  case $order_path in
    /*) ;;
    *) order_path=${frozen_plan%/*}/$order_path ;;
  esac
  order_text=$(cat "$order_path") || fail "could not read frozen order $order_path"
  [[ $order_text != *'7 days'* ]] || fail "the seven-day override leaked into $order_path"
done <<< "$other_orders"
pass 'the seven-day override reaches only the frozen c2 order'

mkdir -p "$project/docs/architecture"
sed 's/^# Design: /# Technical design: /' "$project/docs/design/helpdesk.md" > "$project/docs/architecture/helpdesk.md"
rm "$project/docs/design/helpdesk.md"
architecture_manifest=$(approval manifest "$test_ticket" "$project" --depth complete) || fail "$architecture_manifest"
sign_manifest "$architecture_manifest"
jq --arg sha "$architecture_manifest" '.muster.manifest_sha = $sha' "$plan" > "$T/plan.json"
mv "$T/plan.json" "$plan"
architecture_plan=$(approval verify-plan "$test_ticket" "$plan" 2>"$T/plan.stderr") ||
  fail "the architecture pack did not verify: $architecture_plan $(cat "$T/plan.stderr")"
assert_contains "$architecture_plan" 'plan ok:' 'the architecture pack passes verify-plan'
[ ! -s "$T/plan.stderr" ] || fail 'the architecture pack emitted a warning'
printf 'Architecture plan verified. %s\n' "$architecture_plan"

if [ -n "${DONE_DONE_EVIDENCE_ROOT:-}" ]; then
  revision=$(git -C "$ROOT" rev-parse --short HEAD)
  jq -n --arg version "juggernaut@$revision" --arg changed "$rejection" \
    --arg refused "$plan_rejection" --arg order "$selected_line" '{
      target: {version: $version},
      start: "An isolated help desk project and local sign-off board for Umer to approve a complete Muster.",
      steps: [
        "Answer the quick-reply question and accept the measurable response-time target.",
        "Close the coverage categories and approve the requirements pack.",
        "Change the approved target and check that the pack needs fresh approval.",
        "Restore the target, mark Performance Open, approve the altered pack and verify its plan.",
        "Restore and sign the original pack, regenerate its plan and register demo at complete depth.",
        "Override retention for c2, start the swarm with dispatch disabled and inspect the frozen orders."
      ],
      result: ([$changed, $refused, $order] | join("\n"))
    }' > "$DONE_DONE_EVIDENCE_ROOT/steps.json"
fi
