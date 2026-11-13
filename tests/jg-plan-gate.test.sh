#!/usr/bin/env bash
# bin/jg-plan-gate.sh and core/plan-gate/check.sh through their real callers, on real Beads stores
# (JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds; the suite skips without them).
# A row of a lead's store that waits for a row of Main's store is not ready; one tick of the check closes the
# gate when Main's row closes, and the row is ready. The same for a tool version. A plan's approval writes the
# dispatch approval record on each slice of the file, in the home that owns it, and on no other row.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

GATE="$ROOT/bin/jg-plan-gate.sh" CHECK="$ROOT/core/plan-gate/check.sh" T=$(jg_test_tmproot jg-plan-gate)
M=$T/main L=$T/lead
jg_test_beads_home "$M"
jg_test_beads_home "$L"
for h in "$M" "$L"; do : > "$h/config/backlog-intake-loose"; mkdir -p "$h/state" "$h/data"; done
printf 'lead1\n' > "$L/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$M" > "$L/.jg-squad-lead-parent"
printf -- '- lead1 - the test lead (home: %s; scope: tests; projects: juggernaut; added 2026-11-12)\n' "$L" > "$M/data/squad_leads.md"

run() {  # <home> <cmd> <args...>: the command in a home, stdout and stderr together.
  local h=$1 c=$2
  shift 2
  env HOME="$T" TMPDIR="$T" JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_DATA_OVERRIDE="$h/data" \
    JG_CONFIG_OVERRIDE="$h/config" JG_TASK_PRIORITY_CHECK=/nonexistent PATH="$T/tools:$PATH" "$c" "$@" 2>&1
}
bd_() { BEADS_DIR=$(tr -d '[:space:]' < "$1/config/beads-dir") "$ROOT/bin/jg-beads.sh" "${@:2}" 2>/dev/null; }
ready_in() { bd_ "$1" ready --json --limit 0 | jq -r '[.[].id] | sort | join(",")'; }
slice() {  # <home> <slice id> <epic>: a filed slice row of a plan, as bin/jg-plan-file.sh leaves it; prints the row id
  bd_ "$1" create "Slice $2" -p 1 --parent "$3" --metadata "{\"plan_slice\":\"$2\"}" --silent | tail -n 1
}

jg_test_add "$M" jg-plan "[feature] The plan"
jg_test_add "$L" jg-plan "[feature] The plan"
MA=$(slice "$M" A jg-plan); LB=$(slice "$L" B jg-plan); LC=$(slice "$L" C jg-plan)

# A gate on a row of Main's store keeps the lead's row out of ready.
out=$(run "$L" "$GATE" add "$LB" --waits-for "main:$MA") || fail "add: $out"
assert_contains "$out" "gated $LB on home main row $MA" "add must name the condition"
case ",$(ready_in "$L")," in *",$LB,"*) fail "a gated row must not be ready" ;; esac
out=$(run "$L" "$GATE" add "$LB" --waits-for "main:$MA") && fail "the same gate twice must be refused"
assert_contains "$out" "already waits on" "the repeat must say so"
out=$(run "$L" "$GATE" add "$LC" --waits-for nobody:jg-1) && fail "an unknown home must be refused"
assert_contains "$out" "neither main nor a Squad Lead" "the refusal must name the cause"
out=$(run "$L" "$GATE" add "$LC" --waits-for "lead1:$LB") && fail "a row of this home is an edge, not a gate"
out=$(run "$L" "$GATE" add jg-missing --waits-for "main:$MA") && fail "a row not in the store must be refused"

# A tick while Main's row is open closes nothing.
out=$(run "$M" "$CHECK" "$M") || fail "check: $out"
[ -z "$out" ] || fail "a tick with nothing to close must print nothing, got: $out"
case ",$(ready_in "$L")," in *",$LB,"*) fail "the row must stay gated while Main's row is open" ;; esac

# Main's row closes; one tick of Main's check closes the lead's gate, and the row is ready.
bd_ "$M" close "$MA" >/dev/null
out=$(run "$M" "$CHECK" "$M") || fail "check: $out"
assert_contains "$out" "closed" "the tick must say which gate it closed"
case ",$(ready_in "$L")," in *",$LB,"*) ;; *) fail "the row must be ready after one tick, ready: $(ready_in "$L")" ;; esac
out=$(run "$M" "$CHECK" "$M"); [ -z "$out" ] || fail "a second tick must print nothing, got: $out"

# A tool gate closes when the tool reports the version.
mkdir -p "$T/tools"
printf '#!/bin/sh\necho "faketool 0.6.26"\n' > "$T/tools/faketool"; chmod +x "$T/tools/faketool"
run "$L" "$GATE" add "$LC" --tool faketool --min 0.6.27 >/dev/null || fail "tool gate"
run "$M" "$CHECK" "$M" >/dev/null
case ",$(ready_in "$L")," in *",$LC,"*) fail "an old tool version must keep the row gated" ;; esac
printf '#!/bin/sh\necho "faketool 0.6.27"\n' > "$T/tools/faketool"
run "$M" "$CHECK" "$M" >/dev/null
case ",$(ready_in "$L")," in *",$LC,"*) ;; *) fail "the installed version must open the row" ;; esac

# A plan's approval is written on each slice of the file, in its owner's home, and on no other row.
LX=$(bd_ "$L" create "Later slice" -p 1 --parent jg-plan --metadata '{"plan_slice":"X"}' --silent | tail -n 1)
jq -n '{plan: "jg-plan", slices: [{id: "A", owner_home: "main"}, {id: "B", owner_home: "lead1"}, {id: "C", owner_home: "lead1"}]}' > "$T/plan.json"
out=$(run "$L" "$GATE" approve "$T/plan.json" --harness claude --model m --effort high) && fail "a lead home must not approve a plan"
assert_contains "$out" "only Main approves" "the refusal must say who approves"
jq -n '{plan: "jg-plan", slices: [{id: "A", owner_home: "main"}, {id: "Q", owner_home: "lead1"}]}' > "$T/missing.json"
out=$(run "$M" "$GATE" approve "$T/missing.json" --harness claude --model m --effort high) && fail "an unfiled slice must refuse the approval"
assert_contains "$out" "slice Q is not filed" "the refusal must name the slice"
[ ! -e "$M/state/dispatch-approved/$MA" ] || fail "a refused approval must write nothing"
out=$(run "$M" "$GATE" approve "$T/plan.json" --harness claude --model m --effort high) || fail "approve: $out"
assert_contains "$out" "approved 3 slices" "the approval must count the slices"
[ -s "$M/state/dispatch-approved/$MA" ] || fail "Main's slice needs its approval record"
[ -s "$L/state/dispatch-approved/$LB" ] && [ -s "$L/state/dispatch-approved/$LC" ] || fail "the lead's slices need their approval records"
[ ! -e "$L/state/dispatch-approved/$LX" ] || fail "a slice that is not in the file must have no approval"
pass "plan gate: a gate on another home's row or a tool version closes on one tick; a plan's approval reaches each of its slices only"
