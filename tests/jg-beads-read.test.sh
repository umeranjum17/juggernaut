#!/usr/bin/env bash
# The read facts the ticket adapter needs, through the real bin/jg-beads-read.py on a real embedded store with no network:
# the rev moves on every kind of write (a row field, a label, a comment, an edge, a parent) and stays put on a read or a no-op write,
# the cursor list pages the whole store once, leaves closed rows and gates out and matches `bd list`, and the history names
# the commits that changed the row and the columns each changed. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds,
# which skip without them.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

WRAPPER="$ROOT/bin/jg-beads.sh" READ="$ROOT/bin/jg-beads-read.py" T=$(jg_test_tmproot jg-beads-read)
unset BEADS_DB BEADS_DOLT_SHARED_SERVER
mkdir -p "$T/real"
export BEADS_DIR=$T/real/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
"$WRAPPER" init --prefix rd >"$T/init.log" 2>&1 || fail "init: $(cat "$T/init.log")"

bd_() { "$WRAPPER" "$@" 2>/dev/null; }
rev() { "$READ" rev "$1" | cut -f2; }
mint() { bd_ q "$1"; }

# rev: it moves on each kind of write, and only then.
t=$(mint target) a=$(mint edge-a) b=$(mint edge-b)
[ -n "$t" ] && [ -n "$a" ] && [ -n "$b" ] || fail "mint three tickets"
before=$(rev "$t")
[ "$before" = "$(rev "$t")" ] || fail "a read must not move the rev"
moves() {  # <label> <bd args...>: the call must move the rev.
  local label=$1 was now; shift
  was=$(rev "$t")
  bd_ "$@" >/dev/null || fail "$label: the write failed"
  now=$(rev "$t")
  [ "$was" != "$now" ] || fail "$label: the rev did not move"
}
moves "title" update "$t" --title "T2"
moves "same-second title" update "$t" --title "T3"
moves "description" update "$t" -d "D2"
moves "metadata" update "$t" --set-metadata k=v
moves "status" update "$t" -s in_progress
moves "label added" update "$t" --add-label la
moves "label swapped" update "$t" --set-labels lb
moves "comment" comment "$t" hello
moves "dependency added" dep add "$t" "$a"
moves "dependency swapped" dep remove "$t" "$a"
moves "dependency swapped in" dep add "$t" "$b"
moves "dependent added" dep add "$a" "$t"
moves "parent set" update "$t" --parent "$(mint parent)"
was=$(rev "$t"); bd_ update "$t" --title "T3" >/dev/null; bd_ update "$t" --add-label lb >/dev/null
[ "$was" = "$(rev "$t")" ] || fail "a write that changes nothing must not move the rev"
"$READ" rev rd-nope >/dev/null 2>&1 && fail "a missing ticket must be refused"
"$READ" rev "x'; drop table issues; --" >/dev/null 2>&1 && fail "a bad id must be refused"

# list: a cursor walk covers each open row once, with closed rows and gates left out, and agrees with bd list.
for i in $(seq 1 12); do mint "bulk $i" >/dev/null; done
done_id=$(mint to-close); bd_ close "$done_id" >/dev/null
bd_ create "a gate" -t gate >/dev/null
walk=$T/walk.ids pages=0 cursor=
: > "$walk"
while :; do
  out=$("$READ" list --limit 5 ${cursor:+--after "$cursor"}) || fail "list page failed"
  pages=$((pages + 1))
  jq -r '.rows[] | .id + " " + .rev' <<<"$out" >>"$walk"
  [ "$(jq '.rows | length' <<<"$out")" -le 5 ] || fail "a page must hold at most the limit"
  cursor=$(jq -r '.next // empty' <<<"$out")
  [ -n "$cursor" ] || break
  [ "$pages" -lt 50 ] || fail "the walk does not end"
done
[ "$pages" -ge 4 ] || fail "the walk must take several pages, took $pages"
cut -d' ' -f1 "$walk" > "$T/walk-ids"
[ "$(sort "$T/walk-ids" | uniq -d | wc -l)" = 0 ] || fail "a row came twice"
bd_ list --json --limit 0 | jq -r '.[].id' | sort > "$T/bd-ids"
sort "$T/walk-ids" | diff - "$T/bd-ids" >/dev/null || fail "the walk must match bd list: $(sort "$T/walk-ids" | diff - "$T/bd-ids")"
grep -q "^$done_id " "$walk" && fail "a closed row must be left out"
[ "$(grep "^$t " "$walk" | cut -d' ' -f2)" = "$(rev "$t")" ] || fail "a listed row must carry the same rev as rev gives"
"$READ" list --limit 0 >/dev/null 2>&1 && fail "limit 0 must be refused"
"$READ" list --after "x y" >/dev/null 2>&1 && fail "a bad cursor must be refused"

# board: one query gives each row the board can show (open rows, rows closed since the cutoff, no gates) as `show` gives it, rev included.
old_id=$(mint closed-long-ago); bd_ close "$old_id" >/dev/null
bd_ dolt sql -q "update issues set closed_at = '2026-01-01 00:00:00' where id = '$old_id'" >/dev/null 2>&1
since=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
"$READ" board "$since" > "$T/board.json" || fail "board failed"
"$READ" board yesterday >/dev/null 2>&1 && fail "board must refuse a closed-since that is not a UTC stamp"
jq -e --arg d "$done_id" --arg o "$old_id" --argjson n "$(bd_ list --json --limit 0 | jq length)" '([.[].id] | index($d)) != null and ([.[].id] | index($o)) == null and length == $n + 1' "$T/board.json" >/dev/null || fail "board holds a row closed since the cutoff and leaves out one closed before it"
[ "$(jq '[.[] | select(.issue_type == "gate")] | length' "$T/board.json")" = 0 ] || fail "board must leave gates out"
jq -r '.[].id' "$T/board.json" | LC_ALL=C sort -c || fail "board rows must come in id order"
for id in $t $a $b; do
  "$READ" show "$id" > "$T/show.json"
  mine=$(jq -c --arg id "$id" '.[] | select(.id == $id) | {rev, parent, title, status, assignee, labels: (.labels // []), metadata: (.metadata // {}), comment_count, created_at, updated_at,
      deps: [.dependencies[] | [.id, .dependency_type, .status, .issue_type]] | sort, dependents: [.dependents[] | [.id, .dependency_type]] | sort}' "$T/board.json")
  theirs=$(jq -c '.[0] | {rev, parent, title, status, assignee, labels: (.labels // []), metadata: (.metadata // {}), comment_count, created_at, updated_at,
      deps: [(.dependencies // [])[] | [.id, .dependency_type, .status, .issue_type]] | sort, dependents: [(.dependents // [])[] | [.id, .dependency_type]] | sort}' "$T/show.json")
  [ "$mine" = "$theirs" ] || fail "board must give $id as show does: $mine <> $theirs"
done

# history: commits that changed the row, newest first, with the columns each changed.
hist=$("$READ" history "$t") || fail "history failed"
[ "$(wc -l <<<"$hist")" -ge 8 ] || fail "history must list the commits that changed the row: $hist"
grep -q "^[a-z0-9]\{32\}"$'\t'".*"$'\t'"modified"$'\t'"title" <<<"$hist" || fail "a title write must show as a modified commit that changed title: $hist"
grep -q "added" <<<"$hist" || fail "history must end at the commit that added the row"
other=$(mint untouched)
[ "$("$READ" history "$other" | wc -l)" -le 2 ] || fail "another ticket's commits must not show in the history"
"$READ" history rd-nope >/dev/null 2>&1 && fail "history of a missing ticket must be refused"
pass "beads read facts: rev on every write, cursor list, board, history"
