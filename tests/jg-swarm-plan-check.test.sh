#!/usr/bin/env bash
# bin/jg-swarm-plan-check.sh checks a swarm plan file with no store: a good plan of three slices prints its ok line and
# writes nothing; each bad plan below is refused alone with one `refused:` line that names the slice and the reason;
# a plan with two bad slices gets two lines; `files` entries must be paths, two slices of one project that name one
# file need a dependency path between them, and `--repo/--ref` finds each existing path in the ref.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLI="$ROOT/bin/jg-swarm-plan-check.sh"
T=$(jg_test_tmproot jg-swarm-plan-check)
Q='Which colour should the new button be?'

slice() {  # <id> <deps json> [<jq filter to change the slice>]
  jq -n --arg id "$1" --argjson d "$2" \
    '{id: $id, title: ("Make part " + $id + " of it"), owner_home: "main", project: "proj", size: "S", risk: "Low",
      depends_on: $d, files: [("bin/" + $id + ".sh (new)")], machine: null, order: ($id + ".md"), owner_word: null, gate: null}' |
    jq -c "${3:-.}"
}
word() {  # <question>: an owner_word with every field the board needs
  jq -n --arg q "$1" '{question: $q, options: {a: "blue", b: "green"}, why: "The new button is the first thing a user sees.",
    outcomes: {a: "The button is blue.", b: "The button is green."}, recommend: "a", recommend_reason: "Blue matches the rest of the page.",
    default: "a", must: "design-pick"}'
}
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
assert_equals "$out" "wave 1: 2 slices can start at once
plan jg-plan: 3 slices ok" "the wave line, then the ok line"
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
refused "no why" "refused: a: owner_word has no why" \
  "$(case_dir nowhy . "$(slice a '[]' ".owner_word = $(word "$Q" | jq -c 'del(.why)')")")"
refused "13-word question" "refused: a: owner_word question has 13 words, 12 at most" \
  "$(case_dir longq . "$(slice a '[]' ".owner_word = $(word 'Which of the two colours should the new button be on the page?' | jq -c .)")")"
long=$(printf 'x%.0s' $(seq 1 121))
refused "outcome of 121 characters" "refused: a: owner_word outcomes.b is over 120 characters" \
  "$(case_dir longout . "$(slice a '[]' ".owner_word = $(word "$Q" | jq -c --arg l "$long" '.outcomes.b = $l')")")"
refused "no outcome" "refused: a: owner_word has no outcomes.a" \
  "$(case_dir noout . "$(slice a '[]' ".owner_word = $(word "$Q" | jq -c 'del(.outcomes.a)')")")"
refused "no reason for the recommendation" "refused: a: owner_word has no recommend_reason" \
  "$(case_dir norr . "$(slice a '[]' ".owner_word = $(word "$Q" | jq -c 'del(.recommend_reason)')")")"
refused "default not a or b" "refused: a: owner_word default is not a or b" \
  "$(case_dir nodef . "$(slice a '[]' ".owner_word = $(word "$Q" | jq -c '.default = "c"')")")"
refused "option of 81 characters" "refused: a: owner_word options.a is over 80 characters" \
  "$(case_dir longopt . "$(slice a '[]' ".owner_word = $(word "$Q" | jq -c --arg l "${long:0:81}" '.options.a = $l')")")"
refused "why over 200 characters" "refused: a: owner_word why is over 200 characters" \
  "$(case_dir longwhy . "$(slice a '[]' ".owner_word = $(word "$Q" | jq -c --arg l "${long}${long}" '.why = $l')")")"
# T6: the card rule sees the why: a path in it is refused with the card rule's own line; a plain why passes.
refused "a path in the why" "refused: a: owner_word: rule 3, a card names no internal thing and this one says" \
  "$(case_dir pathwhy . "$(slice a '[]' ".owner_word = $(word "$Q" | jq -c '.why = "See data/x/report.md for the options."')")")"
out=$(run "$(case_dir plainwhy . "$(slice a '[]' ".owner_word = $(word "$Q" | jq -c '.why = "The report lists both options."')")")") \
  || fail "a plain why must pass: $out"
refused "gate to no home" "refused: a: gate" "$(case_dir gate . "$(slice a '[]' '.gate = {waits_for: "nohome"}')")"
pass "plan check: each bad plan is refused alone with one line"

# 3. Two bad slices: two refused lines.
p=$(case_dir two . "$(slice 'A.1' '[]')" "$(slice b '[]' '.title = "Fix bin/x now"')")
rc=0
out=$(run "$p") || rc=$?
[ "$rc" = 2 ] || fail "two bad slices: exit 2 expected, got $rc"
assert_equals "$(printf '%s\n' "$out" | grep -c '^refused: ')" 2 "two bad slices give two refused lines"
pass "plan check: two bad slices give two refused lines"

# 4. The `files` entries: paths only, one trailing ` (new)`, no shared file between unordered slices of one project.
refused "files missing" "refused: a: files is missing" "$(case_dir nofiles . "$(slice a '[]' 'del(.files)')")"
refused "files empty" "refused: a: files is missing, empty" "$(case_dir emptyfiles . "$(slice a '[]' '.files = []')")"
refused "files not strings" "refused: a: files is missing, empty, or not a list of strings" \
  "$(case_dir numfiles . "$(slice a '[]' '.files = [1]')")"
refused "prose in files" "refused: a: files entry is not a path: the verify path in bin/jg-trunk.sh" \
  "$(case_dir prose . "$(slice a '[]' '.files = ["bin/x.sh", "the verify path in bin/jg-trunk.sh"]')")"
for bad in "/etc/x" "./bin/x.sh" "../x" "bin/../x" "bin/x,sh" "bin/[x].sh" " (new)"; do
  refused "bad path $bad" "refused: a: files entry is not a path: $bad" \
    "$(case_dir "badpath" . "$(slice a '[]' ".files = [\"$bad\"]")")"
done
p=$(case_dir newok . "$(slice a '[]' '.files = ["tests/new.test.sh (new)", "bin/@a+b-c_1.sh"]')")
out=$(run "$p") || fail "a (new) entry and a plain path must pass: $out"
refused "double new" "refused: a: files entry is not a path: tests/new.test.sh (new) (new)" \
  "$(case_dir newnew . "$(slice a '[]' '.files = ["tests/new.test.sh (new) (new)"]')")"
pass "plan check: a files entry is a path, with at most one trailing (new)"

SHARE='.files = ["bin/x.sh"]'
refused "shared file" "refused: a: shares a file with b and neither depends on the other: bin/x.sh" \
  "$(case_dir share . "$(slice a '[]' "$SHARE")" "$(slice b '[]' "$SHARE")")"
refused "shared file, (new) removed" "shares a file with b and neither depends on the other: bin/x.sh" \
  "$(case_dir sharenew . "$(slice a '[]' "$SHARE")" "$(slice b '[]' '.files = ["bin/x.sh (new)"]')")"
refused "two files shared, one line" "refused: a: shares a file with b and neither depends on the other: bin/x.sh" \
  "$(case_dir sharetwo . "$(slice a '[]' '.files = ["bin/x.sh", "bin/y.sh"]')" "$(slice b '[]' '.files = ["bin/x.sh", "bin/y.sh"]')")"
p=$(case_dir chain . "$(slice a '[]' "$SHARE")" "$(slice b '["a"]' "$SHARE")" "$(slice c '["b"]' "$SHARE")")
out=$(run "$p") || fail "slices ordered by depends_on may share a file: $out"
assert_contains "$out" "wave 1: 1 slices can start at once" "a chain starts one slice"
p=$(case_dir other . "$(slice a '[]' "$SHARE")" "$(slice b '[]' "$SHARE | .project = \"other\"")")
out=$(run "$p") || fail "slices of two projects may name one path: $out"
pass "plan check: unordered slices of one project may not share a file"

# 5. --repo/--ref: an entry not marked (new) must exist in the ref.
R=$T/repo
git init -q -b main "$R" && git -C "$R" config user.email t@example.com && git -C "$R" config user.name t
mkdir -p "$R/bin" && printf 'x\n' > "$R/bin/x.sh" && git -C "$R" add . && git -C "$R" commit -q -m one
git -C "$R" checkout -q -b other && printf 'y\n' > "$R/bin/y.sh" && git -C "$R" add . && git -C "$R" commit -q -m two
git -C "$R" checkout -q main
p=$(case_dir ref . "$(slice a '[]' '.files = ["bin/x.sh", "bin/z.sh (new)"]')")
out=$(run "$p" --repo "$R" --ref main) || fail "a path on main and a (new) path must pass: $out"
out=$(run "$(case_dir refother . "$(slice a '[]' '.files = ["bin/y.sh"]')")" --repo "$R" --ref main) && fail "bin/y.sh is only on another branch: $out"
assert_contains "$out" "refused: a: files entry is not in main: bin/y.sh" "the ref check names the entry"
out=$(run "$p" --repo "$R") && fail "--repo without --ref must be a usage error: $out"
assert_contains "$out" "usage:" "--repo needs --ref"
pass "plan check: --repo and --ref find each existing path in the ref"
