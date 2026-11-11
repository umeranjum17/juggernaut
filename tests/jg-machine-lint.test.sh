#!/usr/bin/env bash
# Behavior test for the statechart lint of core/machines/bin/tablelint.py, through its real caller bin/jg-machine.sh check.
# Every machine table of this repository passes. Each defect of the rule of section 6.12 is refused, and the lint names the state.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh" TABLES="$ROOT/core/machines/tables"
T=$(jg_test_tmproot jg-machine-lint); mkdir -p "$T/t"
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }

# 1. The machines of this repository pass, the ticket machine and its two inner tables among them.
n=0
for f in "$TABLES"/*.tsv; do
  name=$(basename "$f" .tsv); n=$((n + 1))
  OUT=$(bash "$JM" check "$name" 2>&1); RC=$?; expect_code 0 "$RC" "$name lints: $OUT"
done
[ "$n" -ge 14 ] || fail "only $n tables found"
pass "the $n machine tables pass the lint"

# 2. A small valid machine, then one defect at a time. The lint names the state or the event.
base() { # <extra state line> <extra edge line> ...: a three-state machine plus any extra lines
  { tab machine m carrier owner
    tab state start initial 'The record is filed.' - rest go
    tab state work normal 'A worker has it.' - waiting '5m -> alert slow-work'
    tab state ended terminal 'The work is finished.' -
    tab edge '(none)' file start w:f - 'a record is filed' t
    tab edge start go work w:f - 'the worker starts' t
    tab edge work finish ended w:f - 'the worker finishes' t
    tab observer 'echo start'
    for l in "$@"; do printf '%s\n' "$l"; done; } > "$T/t/m.tsv"
}
lint() { OUT=$(JG_MACHINES_TABLES="$T/t" bash "$JM" check m 2>&1); RC=$?; }
base; lint; expect_code 0 "$RC" "the base machine lints: $OUT"; assert_equals "ok m: 3 states, 3 edges" "$OUT" "base golden"

defect() { # <name> <expected text> <line>...
  local name=$1 want=$2; shift 2; base "$@"; lint
  expect_code 1 "$RC" "lint should refuse: $name"; assert_contains "$OUT" "$want" "lint should name: $name"
}
# the five fixtures of the ticket
defect "a waiting state with no timeout" "waiting state idle has no timeout that names an alert or a next move" \
  "$(tab state idle normal 'Nobody works on it.' - waiting -)" "$(tab edge work pause idle w:f - g t)" "$(tab edge idle resume work w:f - g t)"
defect "a state that nothing reaches" "unreachable state orphan" "$(tab state orphan normal 'Nobody gets here.' -)" "$(tab edge orphan leave ended w:f - g t)"
defect "two first events" "two first events: file, again" "$(tab edge '(none)' again start w:f - g t)"
defect "a final state with a way out" "terminal state ended has an exit edge" "$(tab edge ended again work w:f - g t)"
defect "an event with two targets" "event finish from work has two targets: ended, start" "$(tab edge work finish start w:f - g t)"
pass "the five fixture tables fail and the lint names the state"

# 3. The other defects of the rule.
defect "a second initial state" "more than one initial state: start, other" "$(tab state other initial 'Another start.' -)" "$(tab edge other leave ended w:f - g t)"
defect "a rest state that names no wake event" "rest state sleeping names no wake event" \
  "$(tab state sleeping normal 'Nobody owes a move.' - rest nothing)" "$(tab edge work sleep sleeping w:f - g t)" "$(tab edge sleeping wake work w:f - g t)"
defect "a waiting state whose timeout names no alert or move" "waiting state idle has no timeout that names an alert or a next move" \
  "$(tab state idle normal 'Nobody works on it.' - waiting '5m')" "$(tab edge work pause idle w:f - g t)" "$(tab edge idle resume work w:f - g t)"
defect "a dead end that is not final" "dead end stuck is not final" "$(tab state stuck normal 'It cannot move.' -)" "$(tab edge work jam stuck w:f - g t)"
defect "a meaning that is the entry action" "state busy has its entry action as its meaning" \
  "$(tab state busy normal 'Run the worker.' -)" "$(tab edge work run busy w:f 'run the worker' g t)" "$(tab edge busy back work w:f - g t)"
defect "a final mode on a state that is not terminal" "state work2 has the mode final and the kind normal" \
  "$(tab state work2 normal 'Parked for good.' - final)" "$(tab edge work park work2 w:f - g t)"
defect "an event that names an unknown state" "names a state the table lacks" "$(tab edge work lose nowhere w:f - g t)"
defect "a state with no meaning" "state blank has no captain sentence" "$(tab state blank normal '' -)" "$(tab edge work x blank w:f - g t)" "$(tab edge blank y work w:f - g t)"
pass "each other defect of the rule is refused by name"

# 4. A table may say a state is open, with its reason, so it is not a dead end.
defect "a dead end" "dead end stuck is not final" "$(tab state stuck normal 'It cannot move.' -)" "$(tab edge work jam stuck w:f - g t)"
base "$(tab state stuck normal 'It cannot move.' -)" "$(tab edge work jam stuck w:f - g t)" "$(tab open stuck 'No move out of it is recorded yet.')"; lint
expect_code 0 "$RC" "an open state is not a dead end: $OUT"
pass "an open state is not a dead end"
