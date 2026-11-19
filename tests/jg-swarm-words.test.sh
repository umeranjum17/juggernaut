#!/usr/bin/env bash
# bin/jg-swarm-words.sh tends the swarm word rows of a Main home and a lead home from their records: the lead takes
# the owner's pick from Main's answered card so its slice starts, and every answered word row is closed. Cases:
# nothing answered changes nothing; an answer in Main frees the lead's slice and closes both word rows; a second run
# changes nothing; a finished record does nothing; an unreadable Main is named on stderr and the lead's gate stays
# open. A real store is needed: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds; the suite skips
# without them.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

CLI="$ROOT/bin/jg-swarm-words.sh" T=$(jg_test_tmproot jg-swarm-words)
Q='Which colour should the new button be?' W=jg-plan-word-f F=jg-plan.2
sections() { printf '## Captain\nThe plan.\n\n## Ask\n%s\n\n## Why\nA test.\n\n## Done when\nIt passes.\n\n## Acceptance Criteria\nThe output.\n' "$1"; }
run() {  # <home> <args...>: a command in a home's own layout, stdout and stderr together.
  local h=$1
  shift
  env HOME="$T" TMPDIR="$T" JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_DATA_OVERRIDE="$h/data" \
    JG_CONFIG_OVERRIDE="$h/config" "$@" 2>&1
}
add() {  # <home> <owner> <id> <title> [<last body line>]
  run "$1" env JG_ROW_OWNER="$2" "$ROOT/bin/jg-backlog.sh" add "$3" "$4" --priority 2 --kind ship --repo proj \
    --body "$(sections "Build it.")${5:+
$5}" > /dev/null || fail "could not file $3 in $2"
}
gate() {  # <home> <card>: the gates of a card as state, resolution and words
  run "$1" "$ROOT/bin/jg-backlog.sh" questions --all --json \
    | jq -c --arg k "$2" '[.[] | select(.card == $k) | {state, resolution, words}]'
}
rowstate() { run "$1" "$ROOT/bin/jg-backlog.sh" list --all | sed -n "s/^  $2,\\([a-z_]*\\),.*/\\1/p"; }
snapshot() { printf '%s|%s|%s|%s' "$(gate "$M" card-1)" "$(gate "$L" card-1)" "$(rowstate "$M" $W)" "$(rowstate "$L" $W)"; }
blocking_rc() { run "$L" "$ROOT/bin/jg-captain-hold.sh" blocking $F > /dev/null; echo $?; }
rec() {  # <home> <file> <state>: a swarm record in the section 2 or 3 form
  jq -n --arg p "$M/data/swarm/jg-plan/plan.json" --arg s "$3" '{plan: "jg-plan", plan_file: $p, state: $s}' > "$1/data/swarm/jg-plan/$2"
}

build() {  # <case name>: Main M and lead L with the word row, the slice row, the gate and both records
  local h o
  M=$T/$1/main L=$T/$1/lead
  for h in "$M" "$L"; do
    jg_test_beads_home "$h"
    mkdir -p "$h/state" "$h/data/swarm/jg-plan" "$h/projects/proj"
    ln -sn "$ROOT/bin" "$h/bin"
    ln -sn "$ROOT/core" "$h/core"
    ln -sn "$ROOT/toolchain.versions" "$h/toolchain.versions"
    printf -- '- proj [local-trunk +yolo] - the one project (added 2026-11-19)\n' > "$h/data/projects.md"
  done
  printf 'lead1\n' > "$L/.jg-squad-lead-home"
  printf -- '- lead1 - the test lead (home: %s; scope: tests; projects: proj; added 2026-11-19)\n' "$L" > "$M/data/squad_leads.md"
  : > "$L/data/squad_leads.md"
  for h in "$M" "$L"; do
    o=lead1 && [ "$h" != "$M" ] || o=main
    add "$h" "$o" jg-plan "[feature] Run the plan" "Run the plan."
    add "$h" "$o" $W "Owner pick before slice f" "Hold slice f."
  done
  add "$L" lead1 $F "Make part f of it" "linked-to: $W"
  for h in "$M" "$L"; do
    rm -f "$h/config/backlog-intake-loose" # strict intake, as a live home
    run "$h" "$ROOT/bin/jg-captain-hold.sh" design-card card-1 --raised-by $W --title "$Q" > /dev/null || fail "no gate in $h"
  done
  jq -n --arg m "$M" --arg l "$L" --arg w "$W" --arg f "$F" '{plan: "jg-plan", main_home: $m, owner_homes: {main: $m, lead1: $l},
    slices: [{id: "f", row: $f, owner_home: "lead1", word_row: $w, card: "card-1"}]}' > "$M/data/swarm/jg-plan/plan.json"
  rec "$M" swarm.json running
  rec "$L" arm.json armed
}
sweep() {  # <home>...: one run in each home; it must exit 0 and print nothing
  local h out
  for h in "$@"; do
    out=$(run "$h" "$CLI" "$h") || fail "a run in $h must exit 0"
    assert_equals "$out" "" "a run in $h prints nothing"
  done
}

build main-and-lead
# 1. Unanswered: nothing is printed or changed.
before=$(snapshot)
assert_contains "$before" '"state":"open"' "the gates start open"
sweep "$L" "$M"
assert_equals "$(snapshot)" "$before" "an unanswered run changes nothing"
assert_equals "$(blocking_rc)" "0" "the slice stays blocked until the owner answers"

# 2. Answered in Main (what the board-answers check runs): the lead takes his words, then both word rows close.
run "$M" "$ROOT/bin/jg-captain-hold.sh" design-pick card-1 --words "b: green" > /dev/null || fail "the pick in Main"
sweep "$L"
assert_equals "$(gate "$L" card-1)" '[{"state":"closed","resolution":"answered","words":"b: green"}]' "the lead's gate holds his words"
assert_equals "$(rowstate "$L" $W)" "done" "the lead's word row is closed"
assert_equals "$(blocking_rc)" "1" "the slice is free once the pick is in"
sweep "$M"
assert_equals "$(rowstate "$M" $W)" "done" "Main's word row is closed"

# 3. Safe twice.
before=$(snapshot)
sweep "$L" "$M"
assert_equals "$(snapshot)" "$before" "a second run changes nothing"

# 4. A finished record: nothing is done in that home.
build finished
run "$M" "$ROOT/bin/jg-captain-hold.sh" design-pick card-1 --words "b: green" > /dev/null || fail "the pick in Main"
rec "$L" arm.json finished
rec "$M" swarm.json finished
before=$(snapshot)
sweep "$L" "$M"
assert_equals "$(snapshot)" "$before" "a finished record changes nothing in either home"
assert_equals "$(blocking_rc)" "0" "a finished record leaves the lead's gate open"

# 5. Main unreadable: the run exits 0, names the home on stderr, and the lead's gate stays open.
build no-main
run "$M" "$ROOT/bin/jg-captain-hold.sh" design-pick card-1 --words "b: green" > /dev/null || fail "the pick in Main"
jq --arg m "$T/no-main/missing" '.main_home = $m' "$M/data/swarm/jg-plan/plan.json" > "$T/plan.new" && mv "$T/plan.new" "$M/data/swarm/jg-plan/plan.json"
out=$(run "$L" "$CLI" "$L") || fail "a run with Main unreadable must exit 0"
assert_contains "$out" "$T/no-main/missing" "the unreadable home is named"
assert_equals "$(gate "$L" card-1 | jq -r '.[0].state')" "open" "the lead's gate stays open"

pass "jg-swarm-words"
