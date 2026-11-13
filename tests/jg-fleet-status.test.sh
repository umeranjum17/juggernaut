#!/usr/bin/env bash
# Behavior test for the fleet status board (core/fleet-status/board.sh) through its real caller, `juggernaut-axi board`.
# A fixture home holds seeded alerts and steering messages, a copy of the machine tables and links to the real observers.
# It proves: one row per machine and home with the count in each state, a record past its state's time limit, a record in no
# state, a machine with no record lister shown as not wired, a row read past the bound named in unread (not left out), the four
# words, and that the read writes nothing.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AXI="$ROOT/bin/juggernaut-axi"
T=$(jg_test_tmproot jg-fleet-status)
H=$T/home
mkdir -p "$H/state/alerts" "$H/data" "$H/config" "$H/core/machines"
ln -s "$ROOT/bin" "$H/bin"
ln -s "$ROOT/core/machines/observers" "$H/core/machines/observers"
cp -r "$ROOT/core/machines/tables" "$H/core/machines/tables"
export JG_HOME=$H
unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE

alert() {  # <name> <state> [<age seconds>]
  printf 'alert=line-red\nsubject=%s\nprecedence=P1\nrung=1\ntop=4\nsince=1\nrung_at=1\nstate=%s\n' "$1" "$2" > "$H/state/alerts/line-red--$1.rec"
  touch -d "@$(( $(date +%s) - ${3:-0} ))" "$H/state/alerts/line-red--$1.rec"
}
alert old open 3600          # open for an hour: past its 5 m limit
alert fresh open 5           # open now: inside it
alert acked acknowledged 60  # acknowledged for a minute: inside its 10 m limit
alert odd bogus-word 5       # a state word the table does not have: in no state
printf 'working [at=1]: x\n' > "$H/state/lane-a.status"
# the wait machine's observer sleeps past the bound, so that row must be named in unread
sed -i "s|^observer\t.*|observer\tsleep 5; echo working|" "$H/core/machines/tables/wait.tsv"
before=$(cd "$H" && find . -type f -printf '%p %s %T@\n' | sort | md5sum)

export JG_BOARD_BOUND=2
OUT=$("$AXI" board --json 2>"$T/err"); rc=$?
[ "$rc" -eq 0 ] || fail "board exited $rc: $(cat "$T/err")"
printf '%s\n' "$OUT" | jq -e '.schema == "juggernaut-axi.v1" and .view == "board"' >/dev/null || fail "board is not the v1 board view"
row() { printf '%s\n' "$OUT" | jq -c --arg m "$1" '.rows[] | select(.machine == $m)'; }
printf '%s\n' "$OUT" | jq -e '([.rows[].machine] | length) == ([.rows[].machine] | unique | length)' >/dev/null || fail "not one row per machine in one home"
n_tables=$(find "$H/core/machines/tables" -name "*.tsv" | wc -l)
printf '%s\n' "$OUT" | jq -e --argjson n "$n_tables" '(.rows | length) + (.unread | length) == $n' >/dev/null \
  || fail "every table must be a row or named in unread"
pass "one row per machine and home, each table a row or named unread"

row alert | jq -e '.wired and .records == 4 and (.states | contains("open=2") and contains("acknowledged=1")) and .past_limit == 1 and .no_state == 1' >/dev/null \
  || fail "alert row: $(row alert)"
pass "counts per state, one record past its limit, one in no state"

row account | jq -e '.wired == false and .records == 0' >/dev/null || fail "account (no lister) must be shown as not wired: $(row account)"
pass "a machine with no record lister is shown as not wired"

printf '%s\n' "$OUT" | jq -e '[.unread[] | select(.machine == "wait" and (.why | test("not read in 2 s")))] | length == 1' >/dev/null \
  || fail "the slow wait row must be named in unread: $(printf '%s\n' "$OUT" | jq -c .unread)"
pass "a row not read within the bound is named in unread"

printf '%s\n' "$OUT" | jq -e '.words[0] | has("Built") and has("Landed") and has("In use") and has("Released")' >/dev/null \
  || fail "words must hold Built, Landed, In use and Released"
pass "the four delivery words are on the board"

TOON=$("$AXI" board 2>/dev/null) || fail "TOON board failed"
case $TOON in *"rows["*"home,machine,wired,records,states,past_limit,no_state"*) pass "TOON renders the rows as a table" ;; *) fail "TOON rows missing: $TOON" ;; esac

after=$(cd "$H" && find . -type f -printf '%p %s %T@\n' | sort | md5sum)
[ "$before" = "$after" ] || fail "the board wrote to the home"
pass "reading the board writes nothing"
