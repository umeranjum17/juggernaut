#!/usr/bin/env bash
# Behavior test for the slice-8b1 stubs: the machine writers refuse nothing and record nothing, jg-move.sh only logs.
# Slice 8b6 deletes this test together with the stubs. The fixture machine and homes are generated here.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot machines-stub); mkdir -p "$T/tables" "$T/home/config" "$T/home/data"
export JG_MACHINES_TABLES="$T/tables" JG_HOME="$T/home"
unset JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
{ tab machine ticket files tests/machines-stub.test.sh
  tab state draft initial "A draft is being written." -
  tab state review normal "The draft waits for a reviewer." -
  tab state published terminal "The draft is published." -
  tab edge draft submit review author:submit - "the author finishes" t-submit
  tab edge review approve published reviewer:approve - "a reviewer agrees" t-approve
  tab observer "echo draft"; } > "$T/tables/ticket.tsv"
DATA="$T/home/data"
run() { OUT=$(bash "$@" 2>&1); RC=$?; }

# jg-move.sh: an illegal move (draft has no "approve") is recorded and not refused, in plain and in shadow form.
run "$ROOT/bin/jg-move.sh" t-1 approve; expect_code 0 "$RC" "an illegal move is not refused"
assert_equals 1 "$(wc -l <"$DATA/moves.log")" "the illegal move is recorded in moves.log"
assert_contains "$(cat "$DATA/moves.log")" "t-1	draft	approve" "the log line names ticket, state and event"
run "$ROOT/bin/jg-move.sh" --shadow t-1 submit; expect_code 0 "$RC" "a legal shadow move exits 0"
assert_equals 2 "$(wc -l <"$DATA/moves.log")" "the legal move is recorded too"
assert_absent "$DATA/machine-shadow.log" "jg-move.sh writes no shadow log"
run "$ROOT/bin/jg-move.sh" t-1; expect_code 2 "$RC" "a malformed call is a usage error"
pass "jg-move.sh records an illegal move and refuses nothing"

# guard and shadow: exit 0, write nothing, even for an enforced machine and an illegal edge.
printf 'ticket\n' > "$T/home/config/machine-enforce"
run "$ROOT/bin/jg-machine-guard.sh" edge ticket draft published t-1; expect_code 0 "$RC" "the guard allows an illegal edge"
run "$ROOT/bin/jg-machine-guard.sh" edge ticket draft review t-1; expect_code 0 "$RC" "the guard allows a legal edge"
run "$ROOT/bin/jg-machine-guard.sh" flip ticket 0; expect_code 0 "$RC" "flip exits 0"
run "$ROOT/bin/jg-machine-guard.sh" enforced ticket; expect_code 1 "$RC" "no machine is enforced"
run "$ROOT/bin/jg-machine-shadow.sh" --refuse ticket t-1 published; expect_code 0 "$RC" "the shadow call never refuses"
assert_absent "$DATA/machine-shadow.log" "no shadow log is written"
assert_absent "$DATA/machine-moves.log" "no machine move log is written"
pass "guard and shadow exit 0 and write nothing"

# jg-machine.sh: the stubbed commands, then a reader that still works.
run "$ROOT/bin/jg-machine.sh" check ticket; expect_code 0 "$RC" "check exits 0"; assert_equals "" "$OUT" "check prints nothing"
run "$ROOT/bin/jg-machine.sh" reconcile ticket; expect_code 0 "$RC" "reconcile exits 0"; assert_equals "" "$OUT" "reconcile prints nothing"
run "$ROOT/bin/jg-machine.sh" writers ticket; expect_code 0 "$RC" "writers exits 0"; assert_equals "" "$OUT" "writers prints nothing"
run "$ROOT/bin/jg-machine.sh" settled ticket draft approve; expect_code 1 "$RC" "settled exits 1"
run "$ROOT/bin/jg-machine.sh" show ticket t-1; expect_code 0 "$RC" "show still runs"
assert_contains "$OUT" "draft" "show prints the fixture state"
pass "jg-machine.sh stubs and readers"
