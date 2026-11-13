#!/usr/bin/env bash
# A plan file is filed into this home through bin/jg-plan-file.sh on a real Beads store: a plan of 6 slices of
# this home (and one of another home) is filed with the repository label, one edge for each dependency, the file
# list as a field and the plan's row as the epic; `ready` lists only the rows with no open edge; `bd swarm
# validate` passes. A slice with no file list, a dependency that is prose, a dependency across homes, a cycle and
# a second filing are each refused with nothing filed. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned
# builds; the suite skips without them.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

CLI="$ROOT/bin/jg-plan-file.sh" T=$(jg_test_tmproot jg-plan-file)
H=$T/home
jg_test_beads_home "$H"
: > "$H/config/backlog-intake-loose"
mkdir -p "$H/state"

run() {  # <args...>: the command on the fixture home, stdout and stderr together.
  env HOME="$T" TMPDIR="$T" JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
    JG_CONFIG_OVERRIDE="$H/config" JG_TASK_PRIORITY_CHECK=/nonexistent "$CLI" "$@" 2>&1
}
bd_() { BEADS_DIR=$(tr -d '[:space:]' < "$H/config/beads-dir") "$ROOT/bin/jg-beads.sh" "$@" 2>/dev/null; }

# The plan's row and one row that is open already, which a slice may depend on.
jg_test_add "$H" jg-plan "[feature] The plan"
jg_test_add "$H" jg-pre "[feature] A row of the store"

slice() {  # <id> <owner> <files json> <deps json>
  jq -n --arg id "$1" --arg o "$2" --argjson f "$3" --argjson d "$4" \
    '{id: $id, title: ("Slice " + $id), owner_home: $o, project: "juggernaut", size: "S", risk: "Low", depends_on: $d, files: $f, machine: null}'
}
plan() {  # <slice json>...: a plan file on stdout.
  jq -n '{plan: "jg-plan", slices: $ARGS.positional | map(fromjson)}' --args "$@"
}
mine=lead
A=$(slice A "$mine" '["bin/a.sh (new)","tests/a.test.sh (new)"]' '[]')
B=$(slice B "$mine" '["bin/b.sh"]' '["A"]')
C=$(slice C "$mine" '["bin/c.sh"]' '["A"]')
D=$(slice D "$mine" '["bin/d.sh"]' '["B","C"]')
E=$(slice E "$mine" '["bin/e.sh"]' '[]')
F=$(slice F "$mine" '["bin/f.sh"]' '["jg-pre"]')
X=$(slice X other '["bin/x.sh"]' '[]')
rows() { bd_ list --all --limit 0 --json | jq 'length'; }
before=$(rows)

# Refusals file nothing.
plan "$A" "$(slice N "$mine" '[]' '[]')" > "$T/nofiles.json"
out=$(run "$T/nofiles.json" --owner "$mine") && fail "a slice with no file list must be refused"
assert_contains "$out" "slice N has no file list" "the refusal must name the slice"
plan "$A" "$(slice P "$mine" '["bin/p.sh"]' '["see the other ticket"]')" > "$T/prose.json"
out=$(run "$T/prose.json" --owner "$mine") && fail "a dependency written as prose must be refused"
assert_contains "$out" 'neither a slice filed here nor a row of the store' "the refusal must say the dependency is not a row"
plan "$A" "$(slice P "$mine" '["bin/p.sh"]' '["X"]')" "$X" > "$T/cross.json"
out=$(run "$T/cross.json" --owner "$mine") && fail "a dependency on another home's slice must be refused"
assert_contains "$out" "which other owns" "the refusal must name the other owner"
plan "$(slice P "$mine" '["bin/p.sh"]' '["Q"]')" "$(slice Q "$mine" '["bin/q.sh"]' '["P"]')" > "$T/cycle.json"
out=$(run "$T/cycle.json" --owner "$mine") && fail "a cycle must be refused"
assert_contains "$out" "cycle" "the refusal must say cycle"
[ "$(rows)" = "$before" ] || fail "a refused plan must file no row"

# The plan of 6 slices (and one of another home) is filed.
plan "$A" "$B" "$C" "$D" "$E" "$F" "$X" > "$T/plan.json"
out=$(run "$T/plan.json" --owner "$mine" --dry-run) || fail "dry run: $out"
assert_contains "$out" "would file D" "the dry run must list the slices"
[ "$(rows)" = "$before" ] || fail "a dry run must file no row"
out=$(run "$T/plan.json" --owner "$mine") || fail "filing: $out"
assert_contains "$out" "validate passed" "validate must pass"
[ "$(rows)" = $((before + 6)) ] || fail "6 rows must be filed, and none for the other owner's slice"

row_of() { bd_ list --parent jg-plan --all --limit 0 --json | jq -r --arg s "$1" '.[] | select(.metadata.plan_slice == $s) | .id'; }
field() { bd_ show "$(row_of "$1")" --json | jq -r "(if type == \"array\" then .[0] else . end) | $2"; }
[ -z "$(row_of X)" ] || fail "the slice of another home must not be filed"
[ "$(field A '.labels | join(",")')" = "project:juggernaut" ] || fail "the repository label: $(field A '.labels | join(",")')"
[ "$(field A '.metadata.files')" = '["bin/a.sh","tests/a.test.sh"]' ] || fail "files field: $(field A '.metadata.files')"
[ "$(field A '.metadata.new_files')" = '["bin/a.sh","tests/a.test.sh"]' ] || fail "new files field"
[ "$(field B '.metadata.new_files')" = '[]' ] || fail "no new files on B"
[ "$(field D '[.dependencies[] | select(.dependency_type == "blocks") | .id] | length')" = 2 ] || fail "D must hold two edges"
[ "$(field F '[.dependencies[] | select(.dependency_type == "blocks") | .id] | join(",")')" = jg-pre ] || fail "F must wait on the store row"
[ "$(bd_ show jg-plan --json | jq -r '(if type == "array" then .[0] else . end).issue_type')" = epic ] || fail "the plan row must be an epic"

# `ready` offers only the rows with no open edge.
ready=$(bd_ ready --limit 0 --json | jq -r '.[].metadata.plan_slice // empty' | sort | tr '\n' ' ')
[ "$ready" = "A E " ] || fail "ready must list A and E only, got: $ready"

# A second filing of the same plan is refused and files nothing.
out=$(run "$T/plan.json" --owner "$mine") && fail "a second filing must be refused"
assert_contains "$out" "already filed" "the refusal must say it is filed"
[ "$(rows)" = $((before + 6)) ] || fail "a second filing must add no row"

# A plan owned by nobody here is refused.
out=$(run "$T/plan.json" --owner nobody) && fail "an owner with no slice must be refused"
assert_contains "$out" "no slice owned by nobody" "the refusal must name the owner"
pass "plan file: 6 slices filed with label, edges, files, epic and validate; refusals file nothing"
