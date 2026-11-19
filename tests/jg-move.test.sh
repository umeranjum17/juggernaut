#!/usr/bin/env bash
# Behavior test for bin/jg-move.sh: a move appends one line to data/moves.log (kept: core/fleet-status and core/lead-sweep read it).
# The test home holds a copy of the ticket tables whose observer reads state/<id>.stage, so no real ticket is touched.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot jg-move); H=$T/home; mkdir -p "$H/core/machines" "$H/state" "$H/data"
cp -r "$ROOT/core/machines/tables" "$ROOT/core/machines/maps" "$ROOT"/core/machines/*.states "$H/core/machines/"
sed -i 's|^observer	.*|observer	cat "$(dirname "$JG_MACHINES_TABLES")/../../state/$1.stage"|' "$H/core/machines/tables/ticket.tsv"
export JG_HOME=$H JG_DATA_OVERRIDE=$H/data JG_MACHINES_TABLES=$H/core/machines/tables
LOG=$H/data/moves.log
mv_() { bash "$ROOT/bin/jg-move.sh" "$@" >/dev/null 2>&1; RC=$?; }

echo building > "$H/state/t1.stage"

# 2. A legal move appends exactly one line: epoch, ticket, from, event, to.
mv_ t1 claim-done; expect_code 0 "$RC" "legal move accepted"
assert_equals 1 "$(wc -l < "$LOG" | tr -d ' ')" "one line appended"
assert_equals "t1	building	claim-done	proving.planned" "$(cut -f2- "$LOG")" "the line names ticket, from, event, to"
pass "a legal move appends one line"

# 3. A ticket with no state yet is logged from (none).
mv_ t2 file; expect_code 0 "$RC" "an unplaced ticket can be filed"
assert_equals "t2	(none)	file" "$(tail -1 "$LOG" | cut -f2-4)" "the first line starts from (none)"
assert_equals 2 "$(wc -l < "$LOG" | tr -d ' ')" "the two moves are logged"
pass "a ticket in no state is logged from (none)"

# 4. The two hot writers call it: a done line and a backlog close each log one move.
status=$H/state/t3.status
echo building > "$H/state/t3.stage"
echo 'done [at=1]: ready' | bash "$ROOT/bin/jg-lavish-guard.sh" --append "$status" || fail "the done line was refused"
assert_equals "t3	building	claim-done	proving.planned" "$(grep "	t3	" "$LOG" | tail -1 | cut -f2-)" "a done line makes claim-done"
echo 'working [at=2]: still going' | bash "$ROOT/bin/jg-lavish-guard.sh" --append "$status" || fail "a working line was refused"
assert_equals 1 "$(grep -c "	t3	" "$LOG")" "only the done line moves the ticket"
echo released > "$H/state/t4.stage"
bash -c '. "$1/bin/jg-backlog-transition-lib.sh"; jg_backlog_close_transition "" "$2/state/t4.marker" "$2/data" t4 "$2/state"' _ "$ROOT" "$H" >/dev/null 2>&1
assert_equals "t4	released	close	closed" "$(grep "	t4	" "$LOG" | tail -1 | cut -f2-)" "a close makes the close move"
assert_equals 1 "$(grep -c "	t4	" "$LOG")" "one move for one close"
pass "a done line and a close each log one move"
