#!/usr/bin/env bash
# Slice jgp-r6-s4 of the rules-and-guards plan: an illegal ticket move is refused BEFORE the authoritative write, through the real writers on a real
# Beads store in an isolated home with the ticket machine enforced. Each case drives the writer, then reads the record: a refused move leaves the
# store row, the task record and the move log exactly as they were; a legal move writes them. The writers are the ones the ticket table names:
# bin/jg-beads-write.py (add, the file move), bin/jg-backlog-transition-lib.sh (the close, answer and drop moves). The trace and moment writers
# (start, approve, prove-pass, refuse, release, revert-released) have their refusal cases in tests/jg-move-writers.test.sh.
# The shipped config/machine-enforce of a live home is never touched: the isolated home has its own. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name
# the builds; without them the run skips plainly.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

T=$(jg_test_tmproot jg-refusal-before-write); H=$T/home
WRAPPER=$ROOT/bin/jg-beads.sh CLI=$ROOT/bin/jg-backlog.sh
unset BEADS_DB BEADS_DOLT_SHARED_SERVER BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
mkdir -p "$T/store" "$H/config" "$H/data" "$H/state" "$H/core/machines"
# The home holds a copy of the ticket tables whose observer reads state/<ticket>.stage, and the ticket machine is enforced in this home only.
cp -r "$ROOT/core/machines/tables" "$ROOT/core/machines/maps" "$ROOT"/core/machines/*.states "$H/core/machines/"
sed -i 's|^observer	.*|observer	cat "$(dirname "$JG_MACHINES_TABLES")/../../state/$1.stage"|' "$H/core/machines/tables/ticket.tsv"
printf 'ticket\n' > "$H/config/machine-enforce"
export TZ=UTC TMPDIR=$T BEADS_DIR=$T/store/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT JG_HOME=$H JG_DATA_OVERRIDE=$H/data \
  JG_STATE_OVERRIDE=$H/state JG_CONFIG_OVERRIDE=$H/config JG_MACHINES_TABLES=$H/core/machines/tables
printf '%s\n' "$BEADS_DIR" > "$H/config/beads-dir"
: > "$H/config/backlog-intake-loose"

bd() { "$WRAPPER" "$@"; }
axi() { "$CLI" "$@"; }
status() { bd show "$1" --json 2>/dev/null | jq -r 'if type == "array" then .[0] else . end | .status // "missing"'; }
stage() { printf '%s\n' "$2" > "$H/state/$1.stage"; }
moves() { { grep "	$1	" "$H/data/moves.log" 2>/dev/null || true; } | wc -l | tr -d " "; }
refused() {  # <state> <event>: the refusals the guard logged (its line names the state and the event, not the ticket)
  { grep "	ticket	$1	$2	refused$" "$H/data/machine-shadow.log" 2>/dev/null || true; } | wc -l | tr -d " "
}
close() {  # <ticket> [close args]: the real close transition, with a task record the close removes
  local id=$1; shift
  : > "$H/state/$id.meta"
  bash -c '. "$1/bin/jg-backlog-transition-lib.sh"; h=$2; id=$3; shift 3; jg_backlog_close_transition "$h/state/$id.meta" "$h/state/$id.marker" "$h/data" "$id" "$h/state" "$@" || { printf "%s\\n" "${JG_BACKLOG_TRANSITION_ERROR-}"; exit 1; }' \
    _ "$ROOT" "$H" "$id" "$@" >"$T/close.out" 2>&1
}

bd init --prefix jg >"$T/init.log" 2>&1 || fail "init the store: $(cat "$T/init.log")"
before=$(cat "$H/config/machine-enforce")

# 1. add: the file move. A ticket the store does not hold but the observer already places is not new, so the move is refused and no row is written.
stage jg-r1 building
axi add jg-r1 "[feature] an add that is not the first move" --priority 2 --body why >/dev/null 2>&1 && fail "an enforced add of a ticket that reads building must be refused"
[ "$(status jg-r1)" = missing ] || fail "a refused add wrote a row"
[ "$(moves jg-r1)" = 0 ] && [ "$(refused building file)" = 1 ] || fail "a refused add must log one refusal and no move"
rm "$H/state/jg-r1.stage"
axi add jg-r1 "[feature] a first move" --priority 2 --body why >/dev/null || fail "a ticket the observer cannot place files with its first move"
[ "$(status jg-r1)" = open ] && [ "$(moves jg-r1)" = 1 ] || fail "a legal add must write the row and one move"
pass "add: an illegal file move writes no row; a legal one writes the row and one move"

# 2. close: building closes (a lane with nothing to land); a refused close leaves the row open, the task record in place and no move.
stage jg-r1 intake
close jg-r1 && fail "a close from intake must be refused when enforced"
[ "$(status jg-r1)" = open ] || fail "a refused close changed the row"
[ -e "$H/state/jg-r1.meta" ] || fail "a refused close removed the task record"
[ "$(moves jg-r1)" = 1 ] && [ "$(refused intake close)" = 1 ] || fail "a refused close must log one refusal and no move: $(cat "$H/data/moves.log" "$H/data/machine-shadow.log" "$T/close.out" 2>&1)"
grep -q 'cannot make the move' "$T/close.out" || fail "the refusal names the move: $(cat "$T/close.out")"
stage jg-r1 building
close jg-r1 || fail "a close from building must go through: $(cat "$T/close.out")"
[ "$(status jg-r1)" = closed ] && [ ! -e "$H/state/jg-r1.meta" ] && [ "$(moves jg-r1)" = 2 ] || fail "a legal close must close the row, remove the record and log one move"
pass "close: a refused close leaves the row open and the task record in place; a legal close writes both"

# 3. drop and answer: the close transition picks the table's event for the state. A ticket that never started closes as a drop when the note says so; a Recon in proving answers.
axi add jg-r2 "[feature] dropped before it started" --priority 2 --body why >/dev/null || fail "file jg-r2"
stage jg-r2 ready
close jg-r2 --note dropped || fail "a ticket that never started can be dropped: $(cat "$T/close.out")"
grep -q "	jg-r2	ready	drop	closed" "$H/data/moves.log" || fail "the drop move was not logged: $(cat "$H/data/moves.log")"
axi add jg-r3 "[feature] a recon answered" --priority 2 --body why >/dev/null || fail "file jg-r3"
stage jg-r3 proving.running
close jg-r3 || fail "a Recon in proving closes by its answer: $(cat "$T/close.out")"
grep -q "	jg-r3	proving.running	answer	closed" "$H/data/moves.log" || fail "the answer move was not logged: $(cat "$H/data/moves.log")"
axi add jg-r4 "[feature] a drop of a ticket that is already closed" --priority 2 --body why >/dev/null || fail "file jg-r4"
stage jg-r4 closed
close jg-r4 --note dropped && fail "a drop of a closed ticket is not a table move and must be refused"
[ "$(status jg-r4)" = open ] || fail "a refused drop changed the row"
stage jg-r4 ready
close jg-r4 && fail "a plain close of a ticket that never started is not a drop and must be refused"
[ "$(status jg-r4)" = open ] || fail "a refused plain close changed the row"
pass "drop and answer: each is the table's own event for the state; a move the table lacks is refused and writes nothing"

# 4. The switch of this home was never touched by the run, and the shipped tree holds no enforcement file.
[ "$(cat "$H/config/machine-enforce")" = "$before" ] || fail "the isolated home's switch changed"
[ ! -e "$ROOT/config/machine-enforce" ] || fail "the repository tree holds a config/machine-enforce"
pass "enforcement is the isolated home's own file; the repository ships none"
