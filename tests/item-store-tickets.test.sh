#!/usr/bin/env bash
# The ticket tables of the one item store: import, ready, the copy written beside Beads by bin/jg-backlog.sh, the daily
# compare, and the one-id-one-home rule. A stand-in bd keeps rows in a file and answers the calls the write verbs make.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FX=$ROOT/tests/fixtures/item-store-tickets
TK=$ROOT/core/item-store/adapters/tickets.py
T=$(jg_test_tmproot item-store-tickets)
sha_of() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
mkdir -p "$T/home/config" "$T/home/data" "$T/home/state"
: > "$T/home/config/backlog-intake-loose"
# A version-manager shim of python3 reads the caller's own config and breaks under a throwaway HOME: run the real interpreter.
mkdir -p "$T/py"; for _py in /usr/bin/python3 /usr/local/bin/python3 "$(command -v python3)"; do [ -x "$_py" ] && { ln -sf "$_py" "$T/py/python3"; break; }; done
export PATH=$T/py:$PATH
export JG_HOME=$T/home JG_DATA_OVERRIDE=$T/home/data JG_STATE_OVERRIDE=$T/home/state BEADS_ACTOR=main
unset JG_TASK_ID JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_ROOT_OVERRIDE
DB=$T/home/state/item-store/fleet.db
sql() { python3 -c 'import sqlite3,sys; [print("|".join(map(str,r))) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2])]' "$DB" "$1"; }

# --- import, ready
out=$(python3 "$TK" import --home main "$FX/export.jsonl"); expect_code 0 $? "import loads the fixture"
[ "$(sql 'SELECT count(*) FROM ticket')" = 11 ] || fail "import: 11 tickets expected, got $(sql 'SELECT count(*) FROM ticket')"
[ "$(sql 'SELECT count(*) FROM link')" = 3 ] || fail "import: one link of each type expected"
[ "$(sql "SELECT external_ref FROM ticket WHERE id='jg-pr'")" = https://github.com/o/r/pull/7 ] || fail "import keeps external_ref"
[ "$(python3 "$TK" ready --now 2026-11-20T00:00:00Z)" = "$(cat "$FX/ready.expected")" ] || fail "ready differs from the recorded bd ready ids: $(python3 "$TK" ready --now 2026-11-20T00:00:00Z | tr '\n' ' ')"
pass "import and ready: the past-date deferred row is in; the future one, the gate and the ephemeral row are out"
python3 "$TK" compare "$FX/export.jsonl" >/dev/null; expect_code 0 $? "compare of a fresh import is empty"
[ "$(sql "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('ticket','link','ticket_change')")" = 3 ] || fail "three ticket tables"
pass "import then compare: no difference"

# --- re-import: a changed row updates, an equal row is not rewritten, a new row inserts, a second run is a no-op
cp "$FX/export.jsonl" "$T/resync.jsonl"
log0=$(sql 'SELECT count(*) FROM ticket_change')
out=$(python3 "$TK" import --home main "$T/resync.jsonl"); expect_code 0 $? "re-import of equal rows"
assert_contains "$out" "0 inserted, 0 updated, 11 unchanged" "an equal re-import counts 11 unchanged"
[ "$(sql 'SELECT count(*) FROM ticket_change')" = "$log0" ] || fail "an equal row was rewritten: the log grew"
python3 - "$T/resync.jsonl" <<'PY'
import json, sys
p = sys.argv[1]; rows = [json.loads(l) for l in open(p)]
for r in rows:
    if r["id"] == "jg-ready1": r["title"] = "changed after the first export"; r["labels"].append("later")
rows.append(dict(rows[0], id="jg-resync-new", title="a new row", dependencies=[]))
open(p, "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
out=$(python3 "$TK" import --home main "$T/resync.jsonl"); expect_code 0 $? "re-import with a changed and a new row"
assert_contains "$out" "1 inserted, 1 updated, 10 unchanged" "one inserted, one updated, the rest unchanged"
[ "$(sql "SELECT title FROM ticket WHERE home='main' AND id='jg-ready1'")" = "changed after the first export" ] || fail "the changed row did not update"
[ "$(sql "SELECT count(*) FROM ticket WHERE home='main' AND id='jg-ready1'")" = 1 ] || fail "an update made a second row"
[ "$(sql "SELECT count(*) FROM ticket WHERE id='jg-resync-new'")" = 1 ] || fail "the new row did not insert"
[ "$(sql 'SELECT count(*) FROM ticket_change')" = "$((log0 + 2))" ] || fail "only the two touched rows wrote to the log"
out=$(python3 "$TK" import --home main "$T/resync.jsonl")
assert_contains "$out" "0 inserted, 0 updated, 12 unchanged" "a second run is a no-op"
[ "$(sql 'SELECT count(*) FROM ticket_change')" = "$((log0 + 2))" ] || fail "a second run wrote to the log"
python3 "$TK" compare "$T/resync.jsonl" >/dev/null; expect_code 0 $? "compare is empty after the re-sync"
# put the store back to the fixture for the steps below: the changed row re-imports, the new row is dropped by the log
python3 "$TK" import --home main "$FX/export.jsonl" >/dev/null
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("INSERT INTO ticket_change(at,home,id,verb,source,row,links) VALUES(1,?,?,?,?,NULL,?)",("main","jg-resync-new","test","t:undo","[]")); c.commit()' "$DB"
pass "re-import: a changed row updates, an equal row is not rewritten, a new row inserts, a second run is a no-op"

# --- a ticket is keyed (home, id): two homes may share an id
python3 "$TK" import --home main "$FX/export.jsonl" >/dev/null   # the fixture rows again: the write steps above round-trip rows through bd's export, which has no ephemeral flag
cp "$FX/export.jsonl" "$T/other.jsonl"
python3 - "$T/other.jsonl" <<'PY'      # the same ids in another home: different titles
import json, sys
p = sys.argv[1]; rows = [json.loads(l) for l in open(p)]
for r in rows: r["title"] = "crewhouse " + r["title"]
open(p, "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
out=$(python3 "$TK" import --home crewhouse "$T/other.jsonl"); expect_code 0 $? "an id another home holds imports under its own home: $out"
[ "$(sql "SELECT count(*) FROM ticket WHERE home='crewhouse'")" = 11 ] || fail "crewhouse holds its 11 tickets beside main's"
[ "$(sql "SELECT count(*) FROM ticket WHERE id='jg-ready1'")" = 2 ] || fail "the shared id is two rows"
[ "$(sql "SELECT title FROM ticket WHERE id='jg-ready1' AND home='crewhouse'")" = "crewhouse row ready1" ] || fail "crewhouse reads its own row"
[ "$(sql "SELECT title FROM ticket WHERE id='jg-ready1' AND home='main'")" = "row ready1" ] || fail "main reads its own row"
mkdir -p "$T/crew/state"; printf 'crewhouse\n' > "$T/crew/.jg-squad-lead-home"; printf 'parent_home=%s\n' "$T/home" > "$T/crew/.jg-squad-lead-parent"
out=$(JG_HOME=$T/crew python3 "$TK" compare "$T/other.jsonl"); expect_code 0 $? "compare of crewhouse's export is empty: $out"
[ "$(JG_HOME=$T/crew python3 "$TK" show jg-ready1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')" = "crewhouse row ready1" ] || fail "show reads the caller's own home"
[ "$(python3 "$TK" show crewhouse:jg-ready1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')" = "crewhouse row ready1" ] || fail "show home:id reads the named home"
[ "$(python3 "$TK" ready --now 2026-11-20T00:00:00Z)" = "$(cat "$FX/ready.expected")" ] || fail "ready is scoped to this home: $(python3 "$TK" ready --now 2026-11-20T00:00:00Z | tr "\n" " ") vs $(tr "\n" " " < "$FX/ready.expected")"
pass "two homes share an id: each reads its own row, compare is empty for both"

# --- the stray lead:* copy: dropped only where the plain home exists, run twice safe
python3 "$TK" import --home lead:crewhouse "$T/other.jsonl" >/dev/null; expect_code 0 $? "a stray lead:crewhouse copy imports"
python3 "$TK" import --home lead:ghost "$T/other.jsonl" >/dev/null; expect_code 0 $? "a lead:ghost copy imports (no plain ghost home)"
[ "$(sql "SELECT count(*) FROM link WHERE home LIKE 'lead:%'")" = 6 ] || fail "the stray copies carry links"
plain_before=$(sql "SELECT home, id, title FROM ticket WHERE home NOT LIKE 'lead:%' ORDER BY home, id")
out=$(python3 "$TK" drop-lead-homes); expect_code 0 $? "drop-lead-homes: $out"
[ "$(sql "SELECT count(*) FROM ticket WHERE home='lead:crewhouse'")" = 0 ] || fail "lead:crewhouse rows are dropped"
[ "$(sql "SELECT count(*) FROM link WHERE home='lead:crewhouse'")" = 0 ] || fail "lead:crewhouse links are dropped"
[ "$(sql "SELECT count(*) FROM ticket WHERE home='lead:ghost'")" = 11 ] || fail "lead:ghost has no plain home: kept"
[ "$(sql "SELECT home, id, title FROM ticket WHERE home NOT LIKE 'lead:%' ORDER BY home, id")" = "$plain_before" ] || fail "a plain home's rows changed"
case "$out" in *"11 tickets of lead:crewhouse"*) ;; *) fail "the drop prints what it dropped: $out" ;; esac
log_before=$(sql "SELECT count(*) FROM ticket_change")
out2=$(python3 "$TK" drop-lead-homes); expect_code 0 $? "the second drop runs"
[ "$(sql "SELECT count(*) FROM ticket_change")" = "$log_before" ] || fail "a second drop wrote to the log"
[ "$(sql "SELECT count(*) FROM ticket WHERE home='lead:ghost'")" = 11 ] || fail "a second drop touched lead:ghost"
case "$out2" in *"lead:crewhouse"*) fail "a second drop names a drop again: $out2" ;; esac
pass "drop-lead-homes: removes lead:* rows only where the plain home exists, keeps the rest, a second run changes nothing"

# --- a store made before the key (id unique across homes) is migrated, losing no row
M=$T/old; mkdir -p "$M/state/item-store"
python3 - "$ROOT" "$M" "$FX/export.jsonl" "$TK" <<'PY'
import json, os, sqlite3, sys
root, m, export, tk = sys.argv[1:]
sys.path.insert(0, root + "/core/item-store"); import itemdb
os.makedirs(m + "/config", exist_ok=True)
st = itemdb.open_db(m, "t"); st.con.close()
old = open(root + "/tests/fixtures/item-store-tickets/tickets-before-key.sql").read()
con = sqlite3.connect(m + "/state/item-store/fleet.db"); con.executescript(old)
con.execute("INSERT INTO ticket_change(at,home,id,verb,source,row,links) VALUES(1,'main','jg-a','import','s:1',?,?)",
            (json.dumps({"title": "old a", "labels": "[]", "metadata": "{}", "ephemeral": 0}), json.dumps([{"to": "jg-b", "type": "blocks"}])))
con.execute("INSERT INTO ticket_change(at,home,id,verb,source,row,links) VALUES(2,'main','jg-b','import','s:2',?,'[]')",
            (json.dumps({"title": "old b", "labels": "[]", "metadata": "{}", "ephemeral": 0}),))
con.commit()
PY
JG_HOME=$M python3 "$TK" ready >/dev/null; expect_code 0 $? "opening an old store migrates it"
msql() { python3 -c 'import sqlite3,sys; [print("|".join(map(str,r))) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2])]' "$M/state/item-store/fleet.db" "$1"; }
[ "$(msql 'SELECT count(*) FROM ticket')" = 2 ] || fail "the migration kept both tickets"
[ "$(msql "SELECT home||from_id||to_id FROM link")" = "mainjg-ajg-b" ] || fail "the migration kept the link, now with its home"
[ "$(msql 'SELECT count(*) FROM ticket_change')" = 2 ] || fail "the log was kept"
[ "$(msql "SELECT count(*) FROM sqlite_master WHERE name='ticket_change_old' OR name='ticket_change_home'")" = 0 ] || fail "the old objects are gone"
JG_HOME=$M python3 "$TK" ready >/dev/null; expect_code 0 $? "a migrated store opens again"
pass "an old store migrates to the (home, id) key keeping every ticket, link and log row"

# --- a store made before the link table allowed `tracks` is rebuilt keeping every row, then takes a tracks link
M2=$T/old-link; mkdir -p "$M2/state/item-store" "$M2/config"
python3 - "$ROOT" "$M2" <<'PY'
import json, sqlite3, sys
root, m = sys.argv[1:]
sys.path.insert(0, root + "/core/item-store"); import itemdb
st = itemdb.open_db(m, "t"); st.con.close()
sql = open(root + "/core/item-store/tickets.sql").read().replace(", 'tracks'", "")
con = sqlite3.connect(m + "/state/item-store/fleet.db"); con.executescript(sql)
con.execute("INSERT INTO ticket_change(at,home,id,verb,source,row,links) VALUES(1,'main','jg-a','import','s:1',?,?)",
            (json.dumps({"title": "a", "labels": "[]", "metadata": "{}", "ephemeral": 0}), json.dumps([{"to": "jg-b", "type": "blocks"}])))
con.commit()
PY
JG_HOME=$M2 python3 "$TK" ready >/dev/null; expect_code 0 $? "opening a store with the old link types rebuilds it"
m2sql() { python3 -c 'import sqlite3,sys; [print("|".join(map(str,r))) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2])]' "$M2/state/item-store/fleet.db" "$1"; }
[ "$(m2sql "SELECT from_id||to_id||type FROM link")" = "jg-ajg-bblocks" ] || fail "the rebuild kept the link"
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("INSERT INTO ticket_change(at,home,id,verb,source,row,links) VALUES(2,?,?,?,?,?,?)",("main","jg-a","t","s:2","{\"title\":\"a\"}","[{\"to\":\"external:x\",\"type\":\"tracks\"}]")); c.commit()' "$M2/state/item-store/fleet.db"
[ "$(m2sql "SELECT type FROM link")" = tracks ] || fail "a tracks link is held"
pass "a store with the old link types is rebuilt keeping its rows, and then holds a tracks link"

# --- the store's audit: the ticket tables are known, a stray table is not
audit() { python3 - "$ROOT/core/item-store" "$T/home" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import itemdb
st = itemdb.open_db(sys.argv[2], "tick"); print(len(st.audit(itemdb.stamp(st))))
PY
}
[ "$(audit)" = 0 ] || fail "the audit finds the ticket tables a difference"
python3 -c 'import sqlite3,sys; sqlite3.connect(sys.argv[1]).execute("CREATE TABLE stray(x)")' "$DB"
[ "$(audit)" = 1 ] || fail "an extra table that neither file defines must fail the audit"
jg_item() { (cd "$T/home" && JG_HOME="$T/home" python3 "$ROOT/core/item-store/jg-item" schema-check >/dev/null 2>&1); }
jg_item; expect_code 1 $? "jg-item schema-check also fails on a stray table"
python3 -c 'import sqlite3,sys; sqlite3.connect(sys.argv[1]).execute("DROP TABLE stray")' "$DB"
jg_item; expect_code 0 $? "jg-item schema-check passes with the ticket tables"
pass "audit: the ticket tables pass, a stray table still fails"

# --- check: the tables exist, the sql matches its sha, no row breaks the hold rule
out=$(python3 "$TK" check); expect_code 0 $? "check passes on the imported fixture"
assert_contains "$out" "tickets: ok ($(sql "SELECT count(*) FROM ticket WHERE home='main'") rows)" "check counts this home's rows"
setrow() { python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("UPDATE ticket SET status=?, defer_until=NULL, metadata=? WHERE id=?", sys.argv[2:5]); c.commit()' "$DB" "$1" "$2" jg-ready1; }
setrow blocked '{"hold_reason": " "}'
out=$(python3 "$TK" check); expect_code 2 $? "check refuses a blocked row with a blank hold_reason"
assert_contains "$out" "tickets: jg-ready1: blocked or on hold with no hold_reason" "check names the row and the rule"
setrow deferred '{}'
out=$(python3 "$TK" check); expect_code 2 $? "check refuses a deferred row with no date and no reason"
assert_contains "$out" "tickets: jg-ready1: deferred with no reason" "check names the deferred rule"
mkdir -p "$T/bare/state" "$T/bare/config"
out=$(JG_HOME=$T/bare python3 "$TK" check); expect_code 2 $? "check on a home with no tables"
assert_contains "$out" "tickets: no tables" "check says there are no tables"
[ -z "$(JG_HOME=$T/bare python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT 1 FROM sqlite_master WHERE name=\"ticket\"").fetchone() or "")' "$T/bare/state/item-store/fleet.db")" ] || fail "check must not create the tables"
pass "check: ok on the fixture, names a hold-rule break, says no tables on a bare home"
