#!/usr/bin/env bash
# Behavior test for the fleet status board at scale (core/fleet-status/board.sh, H38b) through its real caller, `juggernaut-axi board`.
# 100 lab leads and Main each write their digest with `board.sh --digest`. Then every observer is made to sleep past the bound: the
# board must still end under 10 s with every row and the right counts, which only a read of the digests can do. A home whose digest is
# late is named in unread, a home with no digest is read live, and the digest's new-move count comes from the observer cursor.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AXI="$ROOT/bin/juggernaut-axi"; BOARD="$ROOT/core/fleet-status/board.sh"
T=$(jg_test_tmproot jg-fleet-status-scale); H=$T/main
TABLES=$T/tables; mkdir -p "$TABLES"
for m in alert worker message presence; do cp "$ROOT/core/machines/tables/$m.tsv" "$TABLES/"; done

mkhome() {  # <dir>: a lab home sharing the lab tables and the real observers, with three open alerts
  mkdir -p "$1/state/alerts" "$1/data" "$1/config" "$1/core/machines"
  ln -sn "$ROOT/bin" "$1/bin"; ln -sn "$ROOT/core/machines/observers" "$1/core/machines/observers"; ln -s "$TABLES" "$1/core/machines/tables"
  for i in 1 2 3; do printf 'alert=line-red\nsubject=s%s\nprecedence=P1\nrung=1\ntop=4\nsince=1\nrung_at=1\nstate=open\n' "$i" > "$1/state/alerts/line-red--s$i.rec"; done
}
mkhome "$H"; : > "$H/data/squad_leads.md"
for n in $(seq 1 100); do
  mkhome "$T/lead-$n"
  printf -- '- lead-%s - lab lead (home: %s; scope: lab; projects: p; added 2026-11-13)\n' "$n" "$T/lead-$n" >> "$H/data/squad_leads.md"
done
printf '1\tt-1\ta\tb\tc\n2\tt-2\ta\tb\tc\n3\tt-3\ta\tb\tc\n4\tt-4\ta\tb\tc\n5\tt-5\ta\tb\tc\n' > "$T/lead-1/data/moves.log"
export JG_HOME=$H; unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE

printf '%s\0' "$H" "$T"/lead-* | xargs -0 -n1 -P8 bash "$BOARD" --digest || fail "a digest was not written"
assert_equals "5" "$(awk -F'\t' 'NR == 1 { print $3 }' "$T/lead-1/data/fleet-status/digest.tsv")" "the digest counts the new moves through the cursor"
bash "$BOARD" --digest "$T/lead-1"
assert_equals "0" "$(awk -F'\t' 'NR == 1 { print $3 }' "$T/lead-1/data/fleet-status/digest.tsv")" "the next digest counts only moves since the last"
pass "a home's digest is written whole and counts new moves from the cursor"

# From here no observer can answer in time: any live read would end in unread.
sed -i "s|^observer\t.*|observer\tsleep 5; echo open|" "$TABLES"/*.tsv
export JG_BOARD_BOUND=10
t0=$(date +%s); OUT=$("$AXI" board --json 2>"$T/err"); rc=$?; t1=$(date +%s)
[ "$rc" -eq 0 ] || fail "board exited $rc: $(cat "$T/err")"
[ $((t1 - t0)) -lt 10 ] || fail "the board took $((t1 - t0)) s with 101 homes, over 10 s"
printf '%s\n' "$OUT" | jq -e '(.rows | length) == 404 and (.unread | length) == 0' >/dev/null \
  || fail "expected 404 rows and none unread: $(printf '%s\n' "$OUT" | jq -c '[(.rows | length), .unread[:3]]')"
printf '%s\n' "$OUT" | jq -e '([.rows[] | select(.machine == "alert")] | length) == 101 and ([.rows[] | select(.machine == "alert")] | all(.records == 3 and .states == "open=3"))' >/dev/null \
  || fail "alert rows must hold 3 open records in each of 101 homes"
pass "101 homes end in $((t1 - t0)) s with every row, read from the digests"

# A late digest is named, not skipped and not shown as current.
sed -i '1s/^#digest\t[0-9]*/#digest\t1/' "$T/lead-7/data/fleet-status/digest.tsv"
OUT=$("$AXI" board --json 2>/dev/null) || fail "board failed with a late digest"
printf '%s\n' "$OUT" | jq -e '([.unread[] | select(.home == "lead-7" and (.why | test("digest is late")))] | length) == 1 and ([.rows[] | select(.home == "lead-7")] | length) == 0' >/dev/null \
  || fail "lead-7 must be named late: $(printf '%s\n' "$OUT" | jq -c .unread)"
printf '%s\n' "$OUT" | jq -e '(.rows | length) == 400' >/dev/null || fail "the other homes must still show"
pass "a home whose digest is late is named in unread"

# A home with no digest is read live (here the two machines with records have slow observers, so the bound names them).
rm -f "$T/lead-8/data/fleet-status/digest.tsv"
JG_BOARD_BOUND=1 OUT=$("$AXI" board --json 2>/dev/null) || fail "board failed with a home without a digest"
printf '%s\n' "$OUT" | jq -e '([.unread[] | select(.home == "lead-8" and (.why | test("not read in 1 s")))] | length) == 2 and ([.rows[] | select(.home == "lead-8")] | length) == 2' >/dev/null \
  || fail "lead-8 must be read live: $(printf '%s\n' "$OUT" | jq -c '[.unread[] | select(.home == "lead-8")]')"
pass "a home with no digest is read live, its rows with records slow enough to pass the bound are named"
