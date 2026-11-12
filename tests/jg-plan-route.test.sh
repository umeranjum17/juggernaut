#!/usr/bin/env bash
# A plan with two owners is routed by bin/jg-plan-route.sh from a test Main home: each slice is filed in its
# owner's store and in no other, and `jg-backlog.sh add --owner` in a home that is not the owner is refused with
# the owner named. A slice with an owner that is not registered, a plan routed from a Squad Lead home, and an
# owner whose dry run fails each file nothing in any store. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the
# pinned builds; the suite skips without them.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

CLI="$ROOT/bin/jg-plan-route.sh" T=$(jg_test_tmproot jg-plan-route)
M=$T/main L=$T/lead
jg_test_beads_home "$M"
jg_test_beads_home "$L"
for h in "$M" "$L"; do : > "$h/config/backlog-intake-loose"; mkdir -p "$h/state" "$h/data"; done
printf 'lead1\n' > "$L/.jg-squad-lead-home"
printf -- '- lead1 - the test lead (home: %s; scope: tests; projects: juggernaut; added 2026-11-12)\n' "$L" > "$M/data/squad_leads.md"
jg_test_add "$M" jg-plan "[feature] The plan"
jg_test_add "$L" jg-plan "[feature] The plan"

route() {  # <home> <args...>: the command in a home, stdout and stderr together.
  local h=$1
  shift
  env HOME="$T" TMPDIR="$T" JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_DATA_OVERRIDE="$h/data" \
    JG_CONFIG_OVERRIDE="$h/config" JG_TASK_PRIORITY_CHECK=/nonexistent "$CLI" "$@" 2>&1
}
bd_() { BEADS_DIR=$(tr -d '[:space:]' < "$1/config/beads-dir") "$ROOT/bin/jg-beads.sh" "${@:2}" 2>/dev/null; }
slices_in() { bd_ "$1" list --parent jg-plan --all --limit 0 --json | jq -r '[.[].metadata.plan_slice] | sort | join(",")'; }
slice() {  # <id> <owner> <deps json>
  jq -n --arg id "$1" --arg o "$2" --argjson d "$3" \
    '{id: $id, title: ("Slice " + $id), owner_home: $o, project: "juggernaut", size: "S", risk: "Low", depends_on: $d, files: ["bin/\($id).sh"], machine: null}'
}
plan() { jq -n '{plan: "jg-plan", slices: $ARGS.positional | map(fromjson)}' --args "$@"; }

plan "$(slice A main '[]')" "$(slice B lead1 '[]')" "$(slice C main '["A"]')" "$(slice D lead1 '["B"]')" > "$T/plan.json"

# Refusals file nothing in either store.
plan "$(slice A main '[]')" "$(slice Z nobody '[]')" > "$T/unknown.json"
out=$(route "$M" "$T/unknown.json") && fail "an owner that is not registered must be refused"
assert_contains "$out" "owner nobody is neither main nor a Squad Lead" "the refusal must name the owner"
out=$(route "$L" "$T/plan.json") && fail "a Squad Lead home must not route"
assert_contains "$out" "only Main routes" "the refusal must say only Main routes"
plan "$(slice A main '[]')" "$(slice B lead1 '["A"]')" > "$T/cross.json"
out=$(route "$M" "$T/cross.json") && fail "a dependency across homes must be refused on the dry run"
assert_contains "$out" "owner lead1:" "the refusal must name the owner whose slices failed"
[ -z "$(slices_in "$M")$(slices_in "$L")" ] || fail "a refused plan must file no row in either store"

# A dry run files nothing.
out=$(route "$M" "$T/plan.json" --dry-run) || fail "dry run: $out"
assert_contains "$out" "would file C" "the dry run must list Main's slices"
[ -z "$(slices_in "$M")$(slices_in "$L")" ] || fail "a dry run must file no row"

# Each slice lands in its owner's store, and in no other.
out=$(route "$M" "$T/plan.json") || fail "routing: $out"
assert_contains "$out" "routed 4 slices" "the route must say what it did"
[ "$(slices_in "$M")" = "A,C" ] || fail "Main's store must hold A and C only, got: $(slices_in "$M")"
[ "$(slices_in "$L")" = "B,D" ] || fail "the lead's store must hold B and D only, got: $(slices_in "$L")"

# The same row offered to the wrong home is refused with the owner named.
lead_backlog() {  # <home> <args...>
  local h=$1
  shift
  (cd "$h" && JG_HOME="$h" JG_CONFIG_OVERRIDE="$h/config" JG_TASK_PRIORITY_CHECK=/nonexistent "$ROOT/bin/jg-backlog.sh" "$@" 2>&1)
}
out=$(lead_backlog "$L" add jg-x "[feature] Wrong home" --priority 1 --repo juggernaut --body "x" --owner main) && fail "a row of another owner must be refused"
assert_contains "$out" "owned by main and this home is lead1" "the refusal must name the owner and this home"
out=$(lead_backlog "$M" add jg-y "[feature] Wrong home" --priority 1 --repo juggernaut --body "y" --owner lead1) && fail "Main must refuse a row of a lead"
assert_contains "$out" "owned by lead1 and this home is main" "Main must name the lead"
plan "$(slice N lead1 '[]')" > "$T/new.json"
out=$(env JG_ROW_OWNER=main bash -c "cd '$L' && JG_HOME='$L' JG_CONFIG_OVERRIDE='$L/config' JG_TASK_PRIORITY_CHECK=/nonexistent '$ROOT/bin/jg-plan-file.sh' '$T/new.json' --owner lead1 2>&1") \
  && fail "the filing command in the wrong home must be refused"
assert_contains "$out" "owned by main and this home is lead1" "the filing command must name the owner"
[ "$(slices_in "$L")" = "B,D" ] || fail "a refused offer must file no row"
lead_backlog "$L" add jg-ok "[feature] Own row" --priority 1 --repo juggernaut --body "ok" --owner lead1 >/dev/null \
  || fail "a row of this home's own owner must be filed"
pass "plan route: slices filed in their owner's store only; a home refuses another owner's row and names the owner"
