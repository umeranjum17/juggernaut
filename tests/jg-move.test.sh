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

# 4. In shadow, the two hot writers call it: a done line and a backlog close each make one legal move and write no shadow line;
#    an illegal move is logged once and the writer still succeeds.
SH=$H/data/machine-shadow.log
status=$H/state/t3.status
echo building > "$H/state/t3.stage"
echo 'done [at=1]: ready' | bash "$ROOT/bin/jg-lavish-guard.sh" --append "$status" || fail "the done line was refused"
assert_equals "t3	building	claim-done	proving.planned" "$(grep "	t3	" "$LOG" | tail -1 | cut -f2-)" "a done line makes claim-done"
echo 'working [at=2]: still going' | bash "$ROOT/bin/jg-lavish-guard.sh" --append "$status" || fail "a working line was refused"
assert_equals 1 "$(grep -c "	t3	" "$LOG")" "only the done line moves the ticket"
[ ! -e "$SH" ] || fail "a legal done line wrote a shadow line: $(cat "$SH")"
echo released > "$H/state/t4.stage"
bash -c '. "$1/bin/jg-backlog-transition-lib.sh"; jg_backlog_close_transition "" "$2/state/t4.marker" "$2/data" t4 "$2/state"' _ "$ROOT" "$H" >/dev/null 2>&1
assert_equals "t4	released	close	closed" "$(grep "	t4	" "$LOG" | tail -1 | cut -f2-)" "a close makes the close move"
assert_equals 1 "$(grep -c "	t4	" "$LOG")" "one move for one close"
[ ! -e "$SH" ] || fail "a legal close wrote a shadow line: $(cat "$SH")"
echo intake > "$H/state/t5.stage"
echo 'done [at=3]: early' | bash "$ROOT/bin/jg-lavish-guard.sh" --append "$H/state/t5.status" || fail "an illegal done line was refused in shadow"
assert_equals 1 "$(wc -l < "$SH" | tr -d ' ')" "an illegal done line logs one shadow line"
assert_contains "$(cat "$SH")" "ticket	intake	claim-done	shadow" "the shadow line names the move"
[ ! -e "$H/data/moves.log" ] || ! grep -q "	t5	" "$LOG" || fail "an illegal move reached the move log"
mv_ --shadow t5 prove-pass; expect_code 0 "$RC" "a shadow call never refuses"
pass "a done line and a close each produce one legal move and no shadow line"

# 5. The switch (J18): with `ticket` listed in config/machine-enforce, the same two writers refuse an illegal move through
#    the real caller and write nothing; delete the line (the rollback) and they carry on in shadow again.
mkdir -p "$H/config"; export JG_CONFIG_OVERRIDE=$H/config
: > "$SH"; echo intake > "$H/state/t6.stage"
echo ticket > "$H/config/machine-enforce"
OUT=$(echo 'done [at=4]: early' | bash "$ROOT/bin/jg-lavish-guard.sh" --append "$H/state/t6.status" 2>&1); RC=$?
expect_code 1 "$RC" "an enforced illegal done line is refused"
assert_contains "$OUT" "cannot make the move claim-done" "the refusal names the move"
[ ! -e "$H/state/t6.status" ] || fail "the refused done line was written"
assert_contains "$(cat "$SH")" "ticket	intake	claim-done	refused" "the refusal is logged as refused"
echo building > "$H/state/t7.stage"
echo 'done [at=6]: ready' | bash "$ROOT/bin/jg-lavish-guard.sh" --append "$H/state/t7.status" || fail "an enforced legal done line was refused"
assert_equals "t7	building	claim-done	proving.planned" "$(grep "	t7	" "$LOG" | tail -1 | cut -f2-)" "a legal done line still moves"
echo intake > "$H/state/t8.stage"
RC=0; bash -c '. "$1/bin/jg-backlog-transition-lib.sh"; jg_backlog_close_transition "" "$2/state/t8.marker" "$2/data" t8 "$2/state"' _ "$ROOT" "$H" >/dev/null 2>&1 || RC=$?
[ "$RC" -ne 0 ] || fail "an enforced illegal close succeeded"
rm "$H/config/machine-enforce"
echo 'done [at=7]: early again' | bash "$ROOT/bin/jg-lavish-guard.sh" --append "$H/state/t6.status" || fail "after the rollback the done line was refused"
assert_contains "$(cat "$SH")" "ticket	intake	claim-done	shadow" "after the rollback the move is logged as shadow"
pass "an enforced ticket table refuses an illegal done line and close; deleting the switch file returns to shadow"
