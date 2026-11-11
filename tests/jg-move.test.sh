#!/usr/bin/env bash
# Behavior test for bin/jg-move.sh: an illegal move exits 1 and changes nothing; a legal one appends one line.
# The test home holds a copy of the ticket tables whose observer reads state/<id>.stage, so no real ticket is touched.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot jg-move); H=$T/home; mkdir -p "$H/core/machines" "$H/state" "$H/data"
cp -r "$ROOT/core/machines/tables" "$ROOT"/core/machines/*.states "$H/core/machines/"
sed -i 's|^observer	.*|observer	cat "$(dirname "$JG_MACHINES_TABLES")/../../state/$1.stage"|' "$H/core/machines/tables/ticket.tsv"
export JG_HOME=$H JG_DATA_OVERRIDE=$H/data JG_MACHINES_TABLES=$H/core/machines/tables
LOG=$H/data/moves.log
mv_() { OUT=$(bash "$ROOT/bin/jg-move.sh" "$@" 2>&1); RC=$?; }

echo building > "$H/state/t1.stage"

# 1. An illegal move (building cannot skip proving) exits 1, names the legal events and writes nothing.
mv_ t1 prove-pass; expect_code 1 "$RC" "illegal move refused"
assert_contains "$OUT" "claim-done" "refusal lists the legal events"
[ ! -e "$LOG" ] || fail "illegal move wrote the log"
mv_ t1 not-an-event; expect_code 1 "$RC" "unknown event refused"
mv_ t1; expect_code 2 "$RC" "missing event is a usage error"
pass "an illegal move exits 1 and changes nothing"

# 2. A legal move appends exactly one line: epoch, ticket, from, event, to.
mv_ t1 claim-done; expect_code 0 "$RC" "legal move accepted"
assert_equals 1 "$(wc -l < "$LOG" | tr -d ' ')" "one line appended"
assert_equals "t1	building	claim-done	proving.planned" "$(cut -f2- "$LOG")" "the line names ticket, from, event, to"
pass "a legal move appends one line"

# 3. A ticket with no state yet accepts only the first event of the machine.
mv_ t2 start; expect_code 1 "$RC" "an unplaced ticket cannot start"
mv_ t2 file; expect_code 0 "$RC" "an unplaced ticket can be filed"
assert_equals "t2	(none)	file	intake" "$(tail -1 "$LOG" | cut -f2-)" "the first line starts from (none)"
assert_equals 2 "$(wc -l < "$LOG" | tr -d ' ')" "only the two legal moves are logged"
pass "a ticket in no state accepts only the first event"
