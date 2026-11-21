#!/usr/bin/env bash
# Journey test for H33: observer cost at 10x records (core/machines/observers, cursor.sh).
# A lab home holds 10 times today's records (data/moves.log, data/trunk-ci.tsv, 300 task records). Every observer is timed through
# its real command line, and each must end under 1 s. The move log is read through core/machines/observers/cursor.sh: the first
# read of a ticket's last move matches a full scan, a later call reads only the new lines, a half-written line waits, and a log
# that was replaced starts the cursor again. The observers only read.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OBS="$ROOT/core/machines/observers"
T=$(cd "$(jg_test_tmproot jg-observers-scale)" && pwd); H=$T/home; S=$H/state; D=$H/data; mkdir -p "$S" "$D" "$H/config" "$H/projects"
export JG_HOME="$H" JG_STATE_OVERRIDE="$S" JG_DATA_OVERRIDE="$D" JG_CONFIG_OVERRIDE="$H/config"
# An observer's cost is the CPU it spends (user + system), not the wall time: a loaded host makes a 0.3 s observer wait seconds for a core.
# cpu_ms <out file> <command...>: run the command with its output in the file, print its CPU milliseconds.
cpu_ms() {
  local out=$1 t; shift
  t=$( { TIMEFORMAT='%U %S'; time "$@" >"$out" 2>&1 </dev/null; } 2>&1 )
  awk -v t="$t" 'BEGIN { split(t, a, " "); printf "%d", (a[1] + a[2]) * 1000 }'
}

# 10x today's records: 305 moves, 18 trunk rows and ~300 tasks today.
awk 'BEGIN { for (i = 1; i <= 3050; i++) printf "%d\tt-%d\tdelivering.queued\tland\tdelivering.landed\n", 1700000000 + i, i % 300 }' > "$D/moves.log"
awk 'BEGIN { for (i = 1; i <= 180; i++) printf "p\tc%d\t%d\t%s\n", i, 1700000000 + i, (i % 9 ? "green" : "red") }' > "$D/trunk-ci.tsv"
for i in $(seq 1 300); do printf 'kind=ship\n' > "$S/t-$i.meta"; printf 'working [at=1700000000]: x\n' > "$S/t-$i.status"; done
printf 'c1\n' > "$S/trunk-tip-p"; printf 'c0\n' > "$S/trunk-green-p"

# 1. Every observer, timed at 10x, ends under 1 s; a timing of observers that print nothing proves nothing, so some must answer.
spoke=0
for f in "$OBS"/*.sh; do
  n=$(basename "$f" .sh); [ "$n" != cursor ] || continue
  ms=$(cpu_ms "$T/obs.out" bash "$f" t-7); echo "observer $n: $ms ms of CPU at 10x records"
  [ ! -s "$T/obs.out" ] || spoke=$((spoke + 1))
  [ "$ms" -lt 1000 ] || fail "observer $n took $ms ms of CPU at 10x records, over 1 s: move it to the cursor"
done
[ "$spoke" -gt 0 ] || fail "no observer printed a state for t-7, the observers did not run"
pass "every observer ends under 1 s at 10x records and some print a state"

# 2. The cursor answers like a full scan.
full() { awk -F'\t' -v t="$1" '$2 == t { l = $0 } END { print l }' "$D/moves.log"; }
ms=$(cpu_ms "$T/cursor.out" bash "$OBS/cursor.sh" last t-7); got=$(cat "$T/cursor.out")
assert_equals "$(full t-7)" "$got" "last move of t-7 matches a full scan"
[ "$ms" -lt 1000 ] || fail "first cursor read took $ms ms of CPU at 10x"
assert_equals "$(wc -c < "$D/moves.log")" "$(head -n1 "$S/observer-cursors/moves.last" | sed 's/^#offset //')" "the cursor stands at the end of the log"
assert_equals "" "$(bash "$OBS/cursor.sh" last nobody)" "a ticket with no move prints nothing"
pass "the first cursor read matches a full scan under 1 s"

# 3. A later call reads only the new lines.
printf '1800000001\tt-7\tdelivering.landed\tmerge\tdelivering.joining\n' >> "$D/moves.log"
assert_equals "$(full t-7)" "$(bash "$OBS/cursor.sh" last t-7)" "the new move of t-7 is seen"
printf '1800000002\tt-8\ta\tb\tc' >> "$D/moves.log"
assert_equals "1700003008" "$(bash "$OBS/cursor.sh" last t-8 | cut -f1)" "a half-written line is not read yet"
printf '\n' >> "$D/moves.log"
assert_equals "1800000002" "$(bash "$OBS/cursor.sh" last t-8 | cut -f1)" "the line is read once it is whole"
# The index is the only state: poison an old row's text in it and see that a call does not re-read the log from byte 0.
sed -i 's/^t-9\t.*/t-9\tKEPT/' "$S/observer-cursors/moves.last"
assert_equals "KEPT" "$(bash "$OBS/cursor.sh" last t-9)" "an old ticket is read from the index, not from the log"
pass "a later call reads only the new lines and waits for a whole line"

# 4. A named reader gets each move once.
first=$(bash "$OBS/cursor.sh" read r1 | wc -l)
assert_equals "3052" "$first" "the first read of a new cursor returns every record"
printf '1800000003\tt-1\ta\tb\tc\n' >> "$D/moves.log"
assert_equals "$(printf '1800000003\tt-1\ta\tb\tc')" "$(bash "$OBS/cursor.sh" read r1)" "the next read returns only the new line"
assert_equals "" "$(bash "$OBS/cursor.sh" read r1)" "nothing new reads nothing"
pass "a named cursor returns each move once"

# 5. A replaced (shorter) log starts the cursor again.
printf '1900000000\tt-7\tx\ty\tz\n' > "$D/moves.log"
assert_equals "$(printf '1900000000\tt-7\tx\ty\tz')" "$(bash "$OBS/cursor.sh" last t-7)" "a replaced log is read from the start"
assert_equals "" "$(bash "$OBS/cursor.sh" last t-8)" "rows of the old log are dropped"
pass "a replaced log resets the cursor"

# 6. The observer only reads: the move log is unchanged by the cursor calls.
assert_equals "1" "$(wc -l < "$D/moves.log")" "cursor calls wrote no move"
bash "$OBS/cursor.sh" >/dev/null 2>&1; expect_code 2 "$?" "no command is a usage error"
