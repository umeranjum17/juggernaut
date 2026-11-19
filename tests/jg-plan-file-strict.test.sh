#!/usr/bin/env bash
# A plan file is filed into a home with strict intake (no config/backlog-intake-loose, as live homes run) through
# bin/jg-plan-file.sh on a real store: each slice row takes the slice title as its plain title and the slice's body
# field as its sections, with the plan and slice named after them. A slice with no body, or a title that is not plain
# words, is refused on the dry run with nothing filed. A home with the loose flag still files a slice with no body.
# JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds; the suite skips without them.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

CLI="$ROOT/bin/jg-plan-file.sh" T=$(jg_test_tmproot jg-plan-file-strict)
H=$T/home
jg_test_beads_home "$H"
mkdir -p "$H/state"
jg_test_add "$H" jg-plan "[feature] The plan"
rm -f "$H/config/backlog-intake-loose"
pass "strict plan file: the fixture home has its store and strict intake"

run() {  # <cmd> <args...>: a command on the fixture home, stdout and stderr together.
  env HOME="$T" TMPDIR="$T" JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
    JG_CONFIG_OVERRIDE="$H/config" "$@" 2>&1
}
rows() { run "$ROOT/bin/jg-backlog.sh" list --all | awk '/^  [^ -]/ { sub(/^  /, ""); print }'; }
body() {  # <id>: the five sections
  printf '## Captain\nThe owner wants slice %s.\n\n## Ask\nBuild slice %s.\n\n## Why\nIt is in the plan.\n\n## Done when\nIts test passes.\n\n## Acceptance Criteria\nThe test passes.\n' "$1" "$1"
}
slice() {  # <id> <title> <deps json> [<body>]
  jq -n --arg id "$1" --arg t "$2" --argjson d "$3" --arg b "${4-}" \
    '{id: $id, title: $t, owner_home: "main", project: "juggernaut", size: "S", risk: "Low", depends_on: $d,
      files: ["bin/\($id).sh (new)"], machine: null} + (if $b == "" then {} else {body: $b} end)'
}
plan() { jq -n '{plan: "jg-plan", slices: $ARGS.positional | map(fromjson)}' --args "$@"; }
before=$(rows | wc -l)

# Refusals on strict intake file nothing.
plan "$(slice A "Make the first part" '[]')" > "$T/nobody.json"
out=$(run "$CLI" "$T/nobody.json" --owner main --dry-run) && fail "a slice with no body must be refused on strict intake"
assert_contains "$out" "needs a body with ## Captain" "the refusal must name the missing sections"
plan "$(slice A "bin/a.sh fix" '[]' "$(body A)")" > "$T/path.json"
out=$(run "$CLI" "$T/path.json" --owner main --dry-run) && fail "a title that is a path must be refused on strict intake"
assert_contains "$out" "slice A: the title is not a readable title" "the refusal must name the slice and the title rule"
[ "$(rows | wc -l)" = "$before" ] || fail "a refused plan must file no row"
pass "strict plan file: a slice with no body or a path title is refused with nothing filed"

# Plain titles and bodies are filed: the row title is the slice title, and the body keeps the sections and the slice.
plan "$(slice A "Make the first part" '[]' "$(body A)")" "$(slice B "Make the second part" '["A"]' "$(body B)")" > "$T/plan.json"
out=$(run "$CLI" "$T/plan.json" --owner main) || fail "filing on strict intake: $out"
assert_contains "$out" "validate passed for jg-plan" "the filing must validate"
row_a=$(printf '%s\n' "$out" | sed -n 's/^filed A as //p')
[ -n "$row_a" ] || fail "the filing must name A's row: $out"
assert_contains "$(rows)" "$row_a,queued,task,juggernaut,Make the first part" "the row title must be the slice title alone"
shown=$(run "$ROOT/bin/jg-backlog.sh" show "$row_a")
assert_contains "$shown" "## Done when" "the row must keep the slice's sections"
assert_contains "$shown" "Plan: jg-plan, slice A (owner main)." "the row must name its plan and slice"
pass "strict plan file: plain titles and bodies are filed and validated"

# A home with the loose flag files a slice with no body, as before.
: > "$H/config/backlog-intake-loose"
jg_test_add "$H" jg-plan2 "[feature] The second plan"
jq -n '{plan: "jg-plan2", slices: [$ARGS.positional[0] | fromjson]}' --args "$(slice C "Make the third part" '[]')" > "$T/loose.json"
out=$(run "$CLI" "$T/loose.json" --owner main) || fail "a loose home must file a slice with no body: $out"
assert_contains "$out" "filed C as" "the loose filing must name C's row"
pass "strict plan file: a loose home still files a slice with no body"
