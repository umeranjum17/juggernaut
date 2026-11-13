#!/usr/bin/env bash
# Behavior test for time per step on the board (core/fleet-status/steps.sh, H48) through its real caller, `juggernaut-axi board --steps`.
# Main and one lead keep a move log with known times; a second lead has no rollup. Each home rolls up on its tick (`board.sh --digest`).
# It proves: n, median, p90 and worst equal a hand count (nearest rank), a move older than 7 days is left out, the records waiting in a
# step are counted with the oldest age, a record in a terminal state is not waiting, the step with the most waiting time leads, a home
# with no rollup is named in unread, and the board reads only the rollups (the move logs are deleted before it runs).
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AXI="$ROOT/bin/juggernaut-axi"; BOARD="$ROOT/core/fleet-status/board.sh"
T=$(jg_test_tmproot jg-fleet-steps); H=$T/main
now=$(date +%s)

mkhome() {  # <dir>: a lab home with the real hold table
  mkdir -p "$1/state" "$1/data" "$1/config" "$1/core/machines"
  ln -s "$ROOT/bin" "$1/bin"; ln -s "$ROOT/core/machines/observers" "$1/core/machines/observers"
  cp -r "$ROOT/core/machines/tables" "$1/core/machines/tables"
}
mv_() {  # <log> <age s> <id> <from> <event> <to>
  printf '%s\thold\t%s\t%s\t%s\t%s\tjg-machine-hold\n' "$(( now - $2 ))" "$3" "$4" "$5" "$6" >> "$1"
}
mkhome "$H"; mkhome "$T/lead-1"; mkhome "$T/lead-2"
: > "$H/data/squad_leads.md"
for n in 1 2; do printf -- '- lead-%s - lab lead (home: %s; scope: lab; projects: p; added 2026-11-14)\n' "$n" "$T/lead-$n" >> "$H/data/squad_leads.md"; done

L=$H/data/machine-moves.log; : > "$L"
# answered -> closed leads on waiting time: h2 to h5 and h9 are answered and never routed (oldest h2, 8800 s).
# raised -> answered took 100, 200, 300, 400 and 1000 s (h9 below adds a sixth, 100 s); h1 was routed (answered -> closed) 50 s after the answer
for r in "h1 100" "h2 200" "h3 300" "h4 400" "h5 1000"; do
  read -r id d <<< "$r"; mv_ "$L" 9000 "$id" '(none)' hold raised; mv_ "$L" $((9000 - d)) "$id" raised answer answered
done
mv_ "$L" 8850 h1 answered route closed
mv_ "$L" 5000 h6 '(none)' hold raised      # waiting 5000 s in raised
mv_ "$L" 2000 h7 '(none)' hold raised      # waiting 2000 s in raised
mv_ "$L" 400 h9 '(none)' hold raised; mv_ "$L" 300 h9 raised answer answered   # waiting 300 s in answered
# 20 days ago: outside the 7 days, so it is not in n (h10 is closed: terminal, not waiting)
mv_ "$L" 1900000 h10 '(none)' hold raised; mv_ "$L" 1800000 h10 raised answer answered; mv_ "$L" 1700000 h10 answered route closed
mv_ "$T/lead-1/data/machine-moves.log" 700 l1 '(none)' hold raised
mv_ "$T/lead-1/data/machine-moves.log" 640 l1 raised answer answered

export JG_HOME=$H; unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE
{ bash "$BOARD" --digest "$H" && bash "$BOARD" --digest "$T/lead-1"; } || fail "a home's tick did not write its rollup"
rm -f "$H/data/machine-moves.log" "$T/lead-1/data/machine-moves.log"   # the board must read the rollups, not the logs

OUT=$("$AXI" board --steps --json 2>"$T/err"); rc=$?
[ "$rc" -eq 0 ] || fail "board --steps exited $rc: $(cat "$T/err")"
printf '%s\n' "$OUT" | jq -e '.schema == "juggernaut-axi.v1" and .view == "board-steps"' >/dev/null || fail "not the board-steps view"
step() { printf '%s\n' "$OUT" | jq -c --arg h "$1" --arg s "$2" '.steps[] | select(.home == $h and .step == $s)'; }

S=$(step primary 'raised -> answered')
printf '%s\n' "$S" | jq -e '.n == 6 and .median_s == 200 and .p90_s == 1000 and .worst_s == 1000' >/dev/null || fail "raised -> answered is not the hand count: $S"
printf '%s\n' "$S" | jq -e '.waiting == 2 and .oldest_s >= 5000 and .oldest_s < 5030' >/dev/null || fail "waiting in raised should be 2, oldest 5000 s: $S"
S=$(step primary 'answered -> closed')
printf '%s\n' "$S" | jq -e '.n == 1 and .median_s == 50 and .worst_s == 50 and .waiting == 5 and .oldest_s >= 8800 and .oldest_s < 8830' >/dev/null || fail "answered -> closed is wrong: $S"
pass "n, median, p90, worst and the waiting records equal the hand count; the 20-day-old move and the closed record are left out"

printf '%s\n' "$OUT" | jq -e '.steps[0].home == "primary" and .steps[0].step == "answered -> closed" and .steps[1].step == "raised -> answered"' >/dev/null || fail "the step with the most waiting time must lead"
step lead-1 'raised -> answered' | jq -e '.n == 1 and .median_s == 60 and .waiting == 0' >/dev/null || fail "lead-1 step is wrong"
printf '%s\n' "$OUT" | jq -e '[.unread[] | select(.home == "lead-2")] | length == 1' >/dev/null || fail "a home with no rollup must be named in unread"
pass "the longest waiting step leads, each home has its own rows, and a home with no rollup is unread"

TOON=$("$AXI" board --steps 2>/dev/null) || fail "the plain board --steps failed"
case "$TOON" in *'raised -> answered'*) ;; *) fail "the TOON view lacks the step: $TOON" ;; esac
"$AXI" board --bogus >/dev/null 2>&1 && fail "board must still refuse an unknown argument"
pass "the plain view renders and an unknown argument is refused"
