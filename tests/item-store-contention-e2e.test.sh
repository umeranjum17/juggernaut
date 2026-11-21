#!/usr/bin/env bash
# fleet.db under load and over time, through the real jg-item, bd_compat.py and tickets.py in a throwaway home:
#   - parallel writers while another process holds the write lock past one busy wait: every item and ticket write lands,
#     none is refused with "database is locked" (store.begin_write: the lock is taken first, waited for, then tried again);
#   - compaction (store.Store.compact, run by `jg-item tick`): a closed or dropped ticket's aged superseded changes are
#     erased, the ticket tables replay from what is left to exactly the rows they hold, open tickets and items are untouched,
#     and the free pages go back to the disk;
#   - a store made before this change (no auto-vacuum, the old never-erase trigger) takes the new trigger when it is opened
#     and is rebuilt with incremental auto-vacuum by its next tick.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ITEM=$ROOT/core/item-store/jg-item
TK=$ROOT/core/item-store/adapters/tickets.py
BD=$ROOT/core/item-store/adapters/bd_compat.py
T=$(jg_test_tmproot item-store-contention)
# A version-manager shim of python3 reads the caller's own config and breaks under a throwaway HOME: run the real interpreter.
mkdir -p "$T/py"; for _py in /usr/bin/python3 /usr/local/bin/python3 "$(command -v python3)"; do [ -x "$_py" ] && { ln -sf "$_py" "$T/py/python3"; break; }; done
export PATH=$T/py:$PATH BEADS_ACTOR=main
unset JG_TASK_ID JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_ROOT_OVERRIDE JG_ITEM_OR_INTAKE

new_home() {  # <dir>: a main home whose store holds the ticket tables
  mkdir -p "$1/config" "$1/state" "$1/data"
  JG_HOME=$1 python3 -I "$TK" import --home main /dev/null >/dev/null || fail "make the tables in $1"
}
sql() {  # <db> <query>
  python3 -c 'import sqlite3,sys; [print("|".join(map(str,r))) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2])]' "$1" "$2"
}

# --- contention: a 16 s lock holder (longer than one busy wait), then 16 item writers and 4 ticket writers at once
H=$T/busy; new_home "$H"; DB=$H/state/item-store/fleet.db
printf '{"id":"jg-c%d","title":"c%d","status":"open","priority":2,"issue_type":"task","created_at":"2026-11-20T00:00:00Z","labels":[],"metadata":{}}\n' 1 1 2 2 3 3 4 4 > "$T/c.jsonl"
JG_HOME=$H python3 -I "$TK" import --home main "$T/c.jsonl" >/dev/null || fail "import the contention tickets"
python3 - "$DB" "$T/held" <<'PY' &
import sqlite3, sys, time
con = sqlite3.connect(sys.argv[1], isolation_level=None)
con.execute("BEGIN IMMEDIATE")
open(sys.argv[2], "w").close()
time.sleep(16)
con.execute("COMMIT")
PY
holder=$!
for _ in $(seq 1 100); do [ -e "$T/held" ] && break; sleep 0.1; done
[ -e "$T/held" ] || fail "the lock holder never took the lock"
start=$(date +%s)
for w in $(seq 1 16); do
  ( for j in 1 2 3 4 5; do
      JG_HOME=$H JG_ITEM_OR_INTAKE=1 "$ITEM" open "intake:main/load-$w-$j" --kind intake --home main --subject jg-c1 --owes "load $w/$j" \
        --source "load:$w/$j" 2>&1
    done > "$T/w$w.out" ) &
done
for w in 1 2 3 4; do
  ( for j in 1 2 3; do JG_HOME=$H python3 -I "$BD" comment "jg-c$w" "load $j" 2>&1 || echo "rc=$?"; done > "$T/b$w.out" ) &
done
wait
wait "$holder" 2>/dev/null
secs=$(( $(date +%s) - start ))
bad=$(cat "$T"/w*.out | grep -vx open)
[ -z "$bad" ] || fail "an item write did not land: $(printf '%s' "$bad" | sort | uniq -c | head -3)"
bad=$(cat "$T"/b*.out | grep -v '^✓ Comment added')
[ -z "$bad" ] || fail "a ticket write did not land: $(printf '%s' "$bad" | head -3)"
[ "$(sql "$DB" "SELECT count(*) FROM item WHERE key LIKE 'intake:main/load-%' AND state='open'")" = 80 ] || fail "80 load items expected"
[ "$(sql "$DB" "SELECT count(*) FROM item WHERE key LIKE 'intake:main/refused-%'")" = 0 ] || fail "a refused write opened an intake item"
[ "$(sql "$DB" "SELECT count(*) FROM ticket_change WHERE verb='comment'")" = 12 ] || fail "12 ticket comments expected"
[ "$secs" -ge 15 ] || fail "the writers finished in ${secs}s: the lock holder did not hold them"
pass "contention: 80 item writes and 12 ticket writes behind a 16 s lock holder all landed (${secs}s), none refused"

# --- compaction: history on a closed, an open and a dropped ticket, then compact
H=$T/compact; new_home "$H"; DB=$H/state/item-store/fleet.db
round() {  # <n>: one export of the main home, every ticket's title and body changed, so each import writes a change per ticket
  python3 - "$1" "$T/r$1.jsonl" <<'PY'
import json, sys
n, out = int(sys.argv[1]), sys.argv[2]
body = "x" * 12000
def row(i, status):
    r = {"id": i, "title": "%s round %d" % (i, n), "description": "%s %d %s" % (i, n, body), "status": status, "priority": 2,
         "issue_type": "task", "created_at": "2026-11-01T00:00:00Z", "labels": ["l"], "metadata": {"round": n},
         "comments": [{"id": "c%d" % k, "author": "main", "text": "note %d" % k, "created_at": "2026-11-02T00:00:00Z"} for k in range(n)]}
    return r
rows = [row("jg-closed", "closed" if n == 4 else "open"), row("jg-open", "open")]
rows[0]["dependencies"] = [{"depends_on_id": "jg-open", "type": "blocks", "created_at": "2026-11-01T00:00:00Z", "created_by": "main", "metadata": "{}"}]
if n == 2:   # the events and provenance streams arrive once; later rounds carry neither, so the fold keeps them from this change
    rows[0]["events"] = [{"kind": "status", "actor": "main", "created_at": "2026-11-03T00:00:00Z"}]
    rows[0]["provenance"] = [{"kind": "commit", "actor": "main", "ref_kind": "git", "ref": "abc", "created_at": "2026-11-03T00:00:00Z"}]
for i in range(6):
    rows.append(row("jg-many%d" % i, "closed"))
open(out, "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
  JG_HOME=$H python3 -I "$TK" import --home main "$T/r$1.jsonl" >/dev/null || fail "import round $1"
}
for n in 1 2 3 4; do round "$n"; done
printf '{"id":"jg-z1","title":"z","status":"open","priority":2,"issue_type":"task","created_at":"2026-11-20T00:00:00Z","labels":[],"metadata":{},"description":"%s"}\n' "$(printf 'z%.0s' $(seq 1 3000))" > "$T/z.jsonl"
JG_HOME=$H python3 -I "$TK" import --home lead:z "$T/z.jsonl" >/dev/null || fail "import the lead home"
JG_HOME=$H python3 -I "$TK" import --home z "$T/z.jsonl" >/dev/null || fail "import the plain home"
JG_HOME=$H python3 -I "$TK" drop-lead-homes >/dev/null || fail "drop the lead home"
JG_HOME=$H "$ITEM" open "intake:main/keep-me" --kind intake --home main --subject jg-open --owes "stay open" --source keep:1 >/dev/null || fail "open an item"
snap() {  # every table compaction must leave as it is
  python3 - "$DB" <<'PY'
import sqlite3, sys, hashlib
c = sqlite3.connect(sys.argv[1])
for t in ("ticket", "link", "comment", "ticket_event", "memory", "item", "move"):
    rows = sorted(map(repr, c.execute("SELECT * FROM " + t)))
    print(t, len(rows), hashlib.sha256("\n".join(rows).encode()).hexdigest())
PY
}
before=$(snap)
log0=$(sql "$DB" "SELECT count(*) FROM ticket_change")
open0=$(sql "$DB" "SELECT count(*) FROM ticket_change WHERE id='jg-open'")
compact() {  # <seconds from now>: the tick's compaction, run as if that much time has passed
  python3 - "$ROOT/core/item-store" "$H" "$1" <<'PY'
import sys, time; sys.path.insert(0, sys.argv[1]); import itemdb
st = itemdb.open_db(sys.argv[2], "tick"); print("%d %d" % st.compact(int(time.time()) + int(sys.argv[3])))
PY
}
[ "$(compact 0 | cut -d' ' -f1)" = 0 ] || fail "a change younger than the 7 days kept was erased"
pages0=$(sql "$DB" "PRAGMA page_count")
out=$(compact $((8 * 86400))) || fail "compact: $out"
[ "$(snap)" = "$before" ] || fail "compaction changed a ticket, link, comment, event, memory, item or move row"$'\n'"$before"$'\n'"$(snap)"
[ "$(sql "$DB" "SELECT count(*) FROM ticket_change WHERE id='jg-open'")" = "$open0" ] || fail "an open ticket lost history"
# jg-closed keeps its first change, the round-2 change that carries its events and provenance, and its latest; each closed
# jg-many keeps its first and latest; the dropped lead copy keeps only its drop
[ "$(sql "$DB" "SELECT count(*) FROM ticket_change WHERE id='jg-closed'")" = 3 ] || fail "the closed ticket keeps 3 changes: $(sql "$DB" "SELECT seq, verb FROM ticket_change WHERE id='jg-closed'")"
[ "$(sql "$DB" "SELECT count(*) FROM ticket_change WHERE id LIKE 'jg-many%'")" = 12 ] || fail "each closed ticket keeps 2 changes"
[ "$(sql "$DB" "SELECT count(*) || ' ' || coalesce(max(row IS NULL), 0) FROM ticket_change WHERE home='lead:z'")" = "1 1" ] || fail "the dropped ticket keeps only its drop"
erased=$(sql "$DB" "SELECT $log0 - count(*) FROM ticket_change")
[ "$(echo "$out" | cut -d' ' -f1)" = "$erased" ] && [ "$erased" -ge 13 ] || fail "compact reported '$out', the log lost $erased changes"
[ "$(sql "$DB" "PRAGMA freelist_count")" = 0 ] || fail "free pages were left in the file"
pages1=$(sql "$DB" "PRAGMA page_count")
[ "$pages1" -lt "$pages0" ] && [ "$(echo "$out" | cut -d' ' -f2)" = $((pages0 - pages1)) ] || fail "the file did not shrink: $pages0 -> $pages1 pages ($out)"
replay() {  # the ticket tables rebuilt from the log alone, against the live tables
  python3 - "$ROOT/core/item-store" "$DB" <<'PY'
import sqlite3, sys
d, live = sys.argv[1], sqlite3.connect(sys.argv[2])
fresh = sqlite3.connect(":memory:")
fresh.executescript(open(d + "/schema.sql").read()); fresh.executescript(open(d + "/tickets.sql").read())
fresh.executemany("INSERT INTO ticket_change VALUES (?,?,?,?,?,?,?,?)", live.execute("SELECT * FROM ticket_change ORDER BY seq"))
for t in ("ticket", "link", "comment", "ticket_event"):
    if sorted(fresh.execute("SELECT * FROM " + t)) != sorted(live.execute("SELECT * FROM " + t)):
        print(t)
PY
}
[ -z "$(replay)" ] || fail "the log left after compaction does not replay to the tables: $(replay)"
pass "compact: $erased aged changes of closed and dropped tickets erased, the tables replay from the rest, the open ticket and the item kept, $((pages0 - pages1)) pages returned"
python3 -c 'import sqlite3,sys; sqlite3.connect(sys.argv[1], isolation_level=None).execute("DELETE FROM ticket_change")' "$DB" || fail "erase the whole log"
[ -z "$(replay)" ] && [ "$(snap)" = "$before" ] || fail "an erase of the whole log took a change the tables are folded from"
pass "an erase of the whole log skips every change the tables are folded from"

# --- an older store: the old trigger and no auto-vacuum; opening moves the trigger, the next tick rebuilds the file
H=$T/old; new_home "$H"; DB=$H/state/item-store/fleet.db
JG_HOME=$H python3 -I "$TK" import --home main "$T/r1.jsonl" >/dev/null || fail "import into the older store"
python3 - "$DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1], isolation_level=None)
c.execute("DROP TRIGGER ticket_change_kept")
c.execute("CREATE TRIGGER ticket_change_kept BEFORE DELETE ON ticket_change BEGIN SELECT RAISE(ABORT, 'ticket_change: a change is never erased'); END")
c.execute("PRAGMA auto_vacuum=NONE"); c.execute("VACUUM")
c.execute("CREATE TABLE gone(x)"); c.executemany("INSERT INTO gone VALUES (?)", [("y" * 4000,)] * 50); c.execute("DROP TABLE gone")   # free pages, as a used store has
PY
[ "$(sql "$DB" "PRAGMA auto_vacuum")" = 0 ] && [ "$(sql "$DB" "PRAGMA freelist_count")" -gt 0 ] || fail "the older store was not made without auto-vacuum and with free pages"
(cd "$H" && JG_HOME=$H "$ITEM" schema-check >/dev/null); expect_code 0 $? "an older store's schema check after it is opened"
assert_contains "$(sql "$DB" "SELECT sql FROM sqlite_master WHERE name='ticket_change_kept'")" "RAISE(IGNORE)" "opening the older store moves its trigger"
out=$(JG_HOME=$H JG_ITEM_TICK_LEASE_S=0 "$ITEM" tick); [ -z "$out" ] || fail "the tick printed: $out"
[ "$(sql "$DB" "PRAGMA auto_vacuum")" = 2 ] && [ "$(sql "$DB" "PRAGMA freelist_count")" = 0 ] || fail "the tick did not rebuild the older store with incremental auto-vacuum"
assert_contains "$(cat "$H/state/item-store/tick.log")" " compact 0 changes " "the tick logs its compaction"
pass "an older store takes the new trigger when opened and incremental auto-vacuum at its next tick"
