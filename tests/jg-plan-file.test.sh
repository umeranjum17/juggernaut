#!/usr/bin/env bash
# A plan file is filed into this home through bin/jg-plan-file.sh on the home's tickets tables: a plan of 6 slices of
# this home (and one of another home) is filed with the repository label, one edge for each dependency, the file
# list as a field and the plan's row as the epic; `ready` lists only the rows with no open edge; `bd swarm
# validate` passes. A slice with no file list, a dependency that is prose, a dependency across homes, a cycle and
# a second filing are each refused with nothing filed. A second filing of the same plan adopts the filed slices and
# files nothing; a row a stop left without its metadata is completed. Every call runs on the home's tickets tables.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLI="$ROOT/bin/jg-plan-file.sh" T=$(jg_test_tmproot jg-plan-file)
H=$T/home
mkdir -p "$H/config" "$H/state" "$H/data"
: > "$H/config/backlog-intake-loose"
pass "plan file: the fixture home has its tickets tables"  # the runner ends a script whose output stops for its whole bound; each phase prints one line

run() {  # <args...>: the command on the fixture home, stdout and stderr together.
  env HOME="$T" TMPDIR="$T" JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
    JG_CONFIG_OVERRIDE="$H/config" "$CLI" "$@" 2>&1
}
bd_() { JG_HOME="$H" python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" "$@" 2>/dev/null; }

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
pass "plan file: each refusal filed nothing"

# The plan of 6 slices (and one of another home) is filed.
plan "$A" "$B" "$C" "$D" "$E" "$F" "$X" > "$T/plan.json"
out=$(run "$T/plan.json" --owner "$mine" --dry-run) || fail "dry run: $out"
assert_contains "$out" "would file D" "the dry run must list the slices"
[ "$(rows)" = "$before" ] || fail "a dry run must file no row"
pass "plan file: the dry run listed the slices and filed nothing"
out=$(run "$T/plan.json" --owner "$mine") || fail "filing: $out"
assert_contains "$out" "validate passed" "validate must pass"
pass "plan file: the plan was filed and validate passed"
[ "$(rows)" = $((before + 6)) ] || fail "6 rows must be filed, and none for the other owner's slice"

row_of() { bd_ list --parent jg-plan --all --limit 0 --json | jq -r --arg s "$1" '.[] | select(.metadata.plan_slice == $s) | .id'; }
field() { bd_ show "$(row_of "$1")" --json | jq -r "(if type == \"array\" then .[0] else . end) | $2"; }
[ -z "$(row_of X)" ] || fail "the slice of another home must not be filed"
# The [feature] title tag is filed as the row's type label (jg-backlog.sh add), beside the repository label.
[ "$(field A '.labels | sort | join(",")')" = "feature,project:juggernaut" ] || fail "the type and repository labels: $(field A '.labels | join(",")')"
[ "$(field A '.metadata.files')" = '["bin/a.sh","tests/a.test.sh"]' ] || fail "files field: $(field A '.metadata.files')"
[ "$(field A '.metadata.new_files')" = '["bin/a.sh","tests/a.test.sh"]' ] || fail "new files field"
[ "$(field B '.metadata.new_files')" = '[]' ] || fail "no new files on B"
[ "$(field D '[.dependencies[] | select(.dependency_type == "blocks") | .id] | length')" = 2 ] || fail "D must hold two edges"
[ "$(field F '[.dependencies[] | select(.dependency_type == "blocks") | .id] | join(",")')" = jg-pre ] || fail "F must wait on the store row"
[ "$(bd_ show jg-plan --json | jq -r '(if type == "array" then .[0] else . end).issue_type')" = epic ] || fail "the plan row must be an epic"
pass "plan file: labels, edges, files and the epic"

# `ready` offers only the rows with no open edge.
ready=$(bd_ ready --limit 0 --json | jq -r '.[].metadata.plan_slice // empty' | sort | tr '\n' ' ')
[ "$ready" = "A E " ] || fail "ready must list A and E only, got: $ready"
pass "plan file: ready lists the rows with no open edge"

# T1: a whole plan filed twice. The second run adopts every slice: it exits 0, names the same rows and files nothing.
first=$(run "$T/plan.json" --owner "$mine" --dry-run | tr '\n' ' ')
assert_contains "$first" "would adopt A as" "the dry run on a filed plan must say adopt, not refuse"
[ "$(rows)" = $((before + 6)) ] || fail "a dry run on a filed plan must file no row"
rowmap() { bd_ list --parent jg-plan --all --limit 0 --json | jq -r '.[] | "\(.metadata.plan_slice) \(.id)"' | sort | tr '\n' ' '; }
map1=$(rowmap)
out=$(run "$T/plan.json" --owner "$mine") || fail "a second filing must be adopted, not refused: $out"
[ "$(grep -c '^filed ' <<<"$out")" = 6 ] || fail "one 'filed <id> as <row>' for each slice: $out"
[ "$(grep -c '^adopted ' <<<"$out")" = 6 ] || fail "each slice must be adopted: $out"
[ "$(rows)" = $((before + 6)) ] || fail "a second filing must add no row"
[ "$(rowmap)" = "$map1" ] || fail "a second filing must change no slice's row"
pass "plan file: a second filing adopted all 6 slices and filed nothing"

# A fresh home for the cases below: the plan, one row of the store, and nothing filed under the plan.
fresh() {  # <name>: sets H, run and bd_ onto a new home with the plan row and the store row.
  H=$T/$1
  mkdir -p "$H/config" "$H/state" "$H/data"
  : > "$H/config/backlog-intake-loose"
  jg_test_add "$H" jg-plan "[feature] The plan"
  jg_test_add "$H" jg-pre "[feature] A row of the store"
}
each_once() {  # every slice of the plan is under it exactly once
  local n
  for n in A B C D E F; do [ "$(bd_ list --parent jg-plan --all --limit 0 --json | jq --arg s "$n" '[.[] | select(.metadata.plan_slice == $s)] | length')" = 1 ] \
    || fail "slice $n must be under the plan exactly once"; done
  [ "$(bd_ list --parent jg-plan --all --limit 0 --json | jq length)" = 6 ] || fail "the plan must hold 6 rows"
}

# T2: stop and resume. A copy of the plan with 2 slices is filed, then the whole plan: 2 adopted, the rest new.
fresh resume
plan "$A" "$B" > "$T/part.json"
run "$T/part.json" --owner "$mine" >/dev/null || fail "the partial plan must file"
rowsA=$(bd_ list --parent jg-plan --all --limit 0 --json | jq -r '.[] | select(.metadata.plan_slice == "A") | .id')
out=$(run "$T/plan.json" --owner "$mine") || fail "the resume: $out"
[ "$(grep -c '^adopted ' <<<"$out")" = 2 ] || fail "2 slices must be adopted: $out"
assert_contains "$out" "filed A as $rowsA" "an adopted slice keeps its row"
each_once
pass "plan file: a resume adopted the 2 filed slices and filed the other 4 once"

# T3: a half row (the slice's title, no metadata) is completed, and no second row is made.
fresh half
jg_test_backlog "$H" add --parent jg-plan "[feature] Slice E" --repo juggernaut --priority 2 --body "half" >/dev/null 2>&1 || fail "the half row"
half=$(bd_ list --parent jg-plan --all --limit 0 --json | jq -r '.[0].id')
[ "$(bd_ list --parent jg-plan --all --limit 0 --json | jq -r '.[0].metadata.plan_slice // "none"')" = none ] || fail "the half row has no plan_slice"
out=$(run "$T/plan.json" --owner "$mine" --dry-run) || fail "dry run: $out"
assert_contains "$out" "would complete E as $half" "the dry run must say complete"
out=$(run "$T/plan.json" --owner "$mine") || fail "completing: $out"
assert_contains "$out" "completed E as $half" "the half row must be completed"
assert_contains "$out" "filed E as $half" "the completed row is named as filed"
[ "$(field E '.metadata.plan_slice')" = E ] || fail "the half row must carry its plan_slice"
[ "$(field E '.metadata.files')" = '["bin/e.sh"]' ] || fail "the half row must carry its files"
each_once
pass "plan file: a half row was completed and no second row was made"

# Two half rows with one slice's title: that slice is refused with both ids, and nothing is filed.
fresh twin
for _ in 1 2; do jg_test_backlog "$H" add --parent jg-plan "[feature] Slice E" --repo juggernaut --priority 2 --body "half" >/dev/null 2>&1 || fail "a half row"; done
out=$(run "$T/plan.json" --owner "$mine") && fail "two half rows for one slice must be refused"
assert_contains "$out" "jg-plan.1 jg-plan.2" "the refusal must name both rows"
[ "$(bd_ list --parent jg-plan --all --limit 0 --json | jq length)" = 2 ] || fail "a refused slice must file no row"
pass "plan file: two half rows for one slice are refused with both ids"

# T4: a stop right after a create leaves one row with no plan_slice; the next run completes it and files the rest.
fresh stop
out=$(JG_PLAN_FILE_STOP_AFTER=1 run "$T/plan.json" --owner "$mine"); st=$?
[ "$st" = 9 ] || fail "the stop hook must exit 9, got $st: $out"
[ "$(bd_ list --parent jg-plan --all --limit 0 --json | jq length)" = 1 ] || fail "the stop must leave one row"
[ "$(bd_ list --parent jg-plan --all --limit 0 --json | jq -r '.[0].metadata.plan_slice // "none"')" = none ] || fail "the stopped row must have no plan_slice"
out=$(run "$T/plan.json" --owner "$mine") || fail "the resume after a stop: $out"
assert_contains "$out" "completed A as" "the stopped row must be completed"
assert_contains "$out" "validate passed" "validate must pass after the resume"
each_once
pass "plan file: a stop after a create was resumed, each slice under the plan once"

# T1 (owner order): a plan with owner_order files every row with the line `Owner order: <ref>.`; --order does the same for a
# plan without the field; a half row lacking the line gets it; a row that has it is not changed.
order_line() { bd_ show "$1" --json | jq -r '(if type == "array" then .[0] else . end).description' | grep -cxF "Owner order: $2."; }
fresh ordered
jq '. + {owner_order: "Main42707"}' "$T/plan.json" > "$T/ordered.json"
jg_test_backlog "$H" add --parent jg-plan "[feature] Slice E" --repo juggernaut --priority 2 --body "half" >/dev/null 2>&1 || fail "the half row"
out=$(run "$T/ordered.json" --owner "$mine") || fail "filing with an owner order: $out"
for n in A B C D E F; do
  [ "$(order_line "$(row_of $n)" Main42707)" = 1 ] || fail "slice $n's row must carry the line 'Owner order: Main42707.' exactly once"
done
assert_contains "$(bd_ show "$(row_of E)" --json | jq -r '.[0].description')" "half" "a completed row keeps its own body"
out=$(run "$T/ordered.json" --owner "$mine") || fail "a second filing: $out"
[ "$(order_line "$(row_of A)" Main42707)" = 1 ] || fail "a second filing must not repeat the order line"
fresh flagged
run "$T/plan.json" --owner "$mine" --order Main7 >/dev/null || fail "filing with --order"
[ "$(order_line "$(row_of A)" Main7)" = 1 ] || fail "--order must put its line on the rows"
fresh flagwins
run "$T/ordered.json" --owner "$mine" --order Main7 >/dev/null || fail "filing with --order over owner_order"
[ "$(order_line "$(row_of A)" Main7)" = 1 ] && [ "$(order_line "$(row_of A)" Main42707)" = 0 ] || fail "--order must win over the plan's owner_order"
fresh plain
run "$T/plan.json" --owner "$mine" >/dev/null || fail "filing with no order"
[ "$(bd_ show "$(row_of A)" --json | jq -r '.[0].description' | grep -c '^Owner order:')" = 0 ] || fail "a plan with no order must add no order line"
out=$(run "$T/plan.json" --owner "$mine" --order "two words") && fail "an order that is not one reference must be refused"
assert_contains "$out" "owner order" "the refusal must name the order"
pass "plan file: every filed row names the owner order, once, and --order wins over owner_order"

# T2: the owner-rules brief gate (the one jg-brief.sh runs, as tests/jg-swarm-arm.test.sh reaches it through the arm) passes a
# row filed with the order line and refuses the same row without it.
gate() {  # <row>: the brief's stderr; rc= on the last line
  local out rc
  out=$(env HOME="$T" JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" JG_CONFIG_OVERRIDE="$H/config" \
    "$ROOT/bin/jg-brief.sh" "${1//./-}" juggernaut --mode local-trunk --ticket "$1" 2>&1 >/dev/null); rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
fresh gate
: > "$H/config/delivery-risk-loose"; printf 'on\n' > "$H/config/owner-rules"; mkdir -p "$H/projects/juggernaut"
run "$T/ordered.json" --owner "$mine" >/dev/null || fail "filing for the gate"
verdict=$(gate "$(row_of A)")
assert_contains "$verdict" "rc=0" "the gate must pass a row with the order line: $verdict"
fresh gate2
: > "$H/config/delivery-risk-loose"; printf 'on\n' > "$H/config/owner-rules"; mkdir -p "$H/projects/juggernaut"
run "$T/plan.json" --owner "$mine" >/dev/null || fail "filing for the refusal"
verdict=$(gate "$(row_of A)")
assert_contains "$verdict" "owner-rules: no owner ask" "the gate must refuse a row with no order line"
pass "plan file: the brief gate passes a row with the order line and refuses one without"

# A plan owned by nobody here is refused.
out=$(run "$T/plan.json" --owner nobody) && fail "an owner with no slice must be refused"
assert_contains "$out" "no slice owned by nobody" "the refusal must name the owner"
pass "plan file: 6 slices filed with label, edges, files, epic and validate; refusals file nothing"
