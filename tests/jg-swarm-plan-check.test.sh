#!/usr/bin/env bash
# bin/jg-swarm-plan-check.sh checks a swarm plan file with no store: a good plan of three slices prints its ok line and
# writes nothing; each bad plan below is refused alone with one `refused:` line that names the slice and the reason;
# a plan with two bad slices gets two lines.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLI="$ROOT/bin/jg-swarm-plan-check.sh"
T=$(jg_test_tmproot jg-swarm-plan-check)
Q='Which colour should the new button be?'

slice() {  # <id> <deps json> [<jq filter to change the slice>]
  jq -n --arg id "$1" --argjson d "$2" \
    '{id: $id, title: ("Make part " + $id + " of it"), owner_home: "main", project: "proj", size: "S", risk: "Low",
      depends_on: $d, files: ["bin/x.sh (new)"], machine: null, order: ($id + ".md"), owner_word: null, gate: null}' |
    jq -c "${3:-.}"
}
word() { jq -n --arg q "$1" '{question: $q, options: {a: "blue", b: "green"}, recommend: "a", must: "design-pick"}'; }
case_dir() {  # <name> <plan filter> <slice json>...: a plan beside its order files; prints the plan path
  local d=$T/$1 f=$2 s
  shift 2
  mkdir -p "$d"
  jq -n '{plan: "jg-plan", title: "Run the probe plan", report: "/tmp/report.md", intent: "Run the probe.",
          prior_art: "Prior art: none needed - a plain check", slices: $ARGS.positional | map(fromjson)}' --args "$@" |
    jq -c "$f" > "$d/plan.json"
  for s in $(jq -r '.slices[].order' "$d/plan.json" 2>/dev/null); do printf 'order\n' > "$d/$s"; done
  printf '%s\n' "$d/plan.json"
}
run() { "$CLI" "$@" 2>&1; }

# 1. A good plan: exit 0, the ok line, no file written.
p=$(case_dir good . "$(slice a '[]')" "$(slice b '["a"]')" \
  "$(slice c '[]' ".owner_word = $(word "$Q" | jq -c .) | .gate = {tool: \"jq\", min: \"1.0\"}")")
before=$(cd "$T/good" && find . | sort | tr '\n' ' ')
out=$(run "$p") || fail "a good plan must exit 0: $out"
assert_equals "$out" "plan jg-plan: 3 slices ok" "the ok line"
assert_equals "$(cd "$T/good" && find . | sort | tr '\n' ' ')" "$before" "the check writes no file"
pass "plan check: a good plan prints its ok line and writes nothing"

# 2. Each bad plan alone: exit 2 and one refused line with the slice and the reason.
refused() {  # <name> <expected text> <plan path>
  local out rc=0
  out=$(run "$3") || rc=$?
  [ "$rc" = 2 ] || fail "$1: exit 2 expected, got $rc: $out"
  assert_equals "$(printf '%s\n' "$out" | grep -c '^refused: ')" 1 "$1: one refused line"
  assert_equals "$(printf '%s\n' "$out" | grep -vc '^refused: ')" 0 "$1: nothing but refused lines"
  assert_contains "$out" "$2" "$1: the line names the problem"
}
A=$(slice a '[]')
mkdir -p "$T/notjson" && printf 'not json {\n' > "$T/notjson/plan.json"
refused "not JSON" "refused: plan: not JSON" "$T/notjson/plan.json"
refused "no prior_art" "refused: jg-plan: no prior_art" "$(case_dir noprior 'del(.prior_art)' "$A")"
refused "id A.1" "refused: A.1: the id" "$(case_dir badid . "$(slice 'A.1' '[]')")"
refused "id twice" "refused: a: the id is used twice" "$(case_dir dupid . "$A" "$A")"
refused "title with a slash" "refused: a: title" "$(case_dir slash . "$(slice a '[]' '.title = "Fix bin/x now"')")"
p=$(case_dir noorder . "$A"); rm "$(dirname "$p")/a.md"
refused "missing order file" "refused: a: the order file" "$p"
refused "depends on nothing" "refused: b: depends_on names no slice: zz" "$(case_dir nodep . "$A" "$(slice b '["zz"]')")"
refused "depends on itself" "refused: a: depends_on names itself" "$(case_dir self . "$(slice a '["a"]')")"
refused "cross-home dependency" "refused: b: depends_on a, which has another owner_home" \
  "$(case_dir cross . "$A" "$(slice b '["a"]' '.owner_home = "lead1"')")"
refused "a loop" "refused: jg-plan: dependency loop" "$(case_dir loop . "$(slice a '["b"]')" "$(slice b '["a"]')")"
refused "one option" "refused: a: owner_word" \
  "$(case_dir oneopt . "$(slice a '[]' ".owner_word = $(word "$Q" | jq -c '.options = {a: "blue"}')")")"
refused "must money" "refused: a: owner_word must is money" \
  "$(case_dir money . "$(slice a '[]' ".owner_word = $(word "$Q" | jq -c '.must = "money"')")")"
out=$(run "$(case_dir intern . "$(slice a '[]' ".owner_word = $(word 'Should jg-plan.3 use blue?' | jq -c .)")")") || true
assert_contains "$out" "refused: a: owner_word" "an internal word in the question is refused"
assert_contains "$out" "jg-plan.3" "the card rules' line names jg-plan.3"
refused "not a question" "refused: a: owner_word" \
  "$(case_dir notq . "$(slice a '[]' ".owner_word = $(word 'Pick the colour' | jq -c .)")")"
refused "gate to no home" "refused: a: gate" "$(case_dir gate . "$(slice a '[]' '.gate = {waits_for: "nohome"}')")"
pass "plan check: each bad plan is refused alone with one line"

# 3. Two bad slices: two refused lines.
p=$(case_dir two . "$(slice 'A.1' '[]')" "$(slice b '[]' '.title = "Fix bin/x now"')")
rc=0
out=$(run "$p") || rc=$?
[ "$rc" = 2 ] || fail "two bad slices: exit 2 expected, got $rc"
assert_equals "$(printf '%s\n' "$out" | grep -c '^refused: ')" 2 "two bad slices give two refused lines"
pass "plan check: two bad slices give two refused lines"
