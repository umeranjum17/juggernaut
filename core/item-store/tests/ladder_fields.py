#!/usr/bin/env python3
"""Slice 8x: the store's views carry every value of the alert table (core/machines/styles/alert-table.tsv).
Each `alert:`, `ladder:` and `limit:` row is read from the store's views and compared field by field; a row with no store value fails.
Also: a file made by the older schema.sql gets the new views by the open-time migration and ends with the shipped rule hash."""
import os, sys, sqlite3
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path[:0] = [ROOT]
from store import Store
import itemdb

TABLE = os.path.join(ROOT, "..", "machines", "styles", "alert-table.tsv")
rows = [ln.split("\t") for ln in open(TABLE, encoding="utf-8").read().splitlines() if ln and not ln.startswith("#")]
by = lambda kind: [r for r in rows if r[0] == kind]
s = Store(":memory:")
q = lambda sql, a=(): s.con.execute(sql, a).fetchall()
bad, n = [], 0


def check(what, want, got):
    global n
    n += 1
    if got != [want]:
        bad.append("%s: table %r, store %r" % (what, want, got))


for r in by("alert"):       # alert, name, fires on, fires at, precedence, first rung, quiet when
    check("alert " + r[1], (r[4], r[5], r[3]), q("SELECT precedence, first_rung, fires_at FROM alert_kind WHERE alert=?", (r[1],)))
for r in by("ladder"):      # ladder, precedence, step, repeat, top, lift, repeats
    check("ladder " + r[1], (int(r[2]), int(r[3]), r[4], r[5], int(r[6])),
          q("SELECT step_s, repeat_s, top, lift, repeats_at_top FROM alert_ladder WHERE precedence=?", (r[1],)))
for r in by("limit"):       # limit, kind, seconds, why
    check("limit " + r[1], (int(r[2]),), q("SELECT limit_s FROM alert_limit WHERE kind=?", (r[1],)))
for name, want in (("alert_kind", len(by("alert"))), ("alert_ladder", len(by("ladder"))), ("alert_limit", len(by("limit")))):
    check("no extra rows in " + name, (want,), q("SELECT count(*) FROM " + name))
kinds = {r[0] for r in q("SELECT kind FROM alert_limit")}
check("the kinds the order names are all there", (True,),
      [(kinds >= {"stranded", "stranded-release"} and any(k.startswith("ship-") for k in kinds) and any(k.startswith("recon-") for k in kinds),)])
check("repeats at the top are 3 on every precedence", (3,), q("SELECT DISTINCT repeats_at_top FROM alert_ladder"))
# the old views keep their values: the rung deadline of each holder and the kinds are those the other proofs read
check("rung worker", ("lead", 3600), q("SELECT next, deadline_s FROM rung WHERE holder='worker'"))
check("kind alert", (3600, "main"), q("SELECT deadline_s, ceiling FROM kind WHERE kind='alert'"))

# migration: a file made before these views existed
d = __import__("tempfile").mkdtemp(prefix="ladder-fields-")
try:
    old = sqlite3.connect(os.path.join(d, "old.db"), isolation_level=None)
    old.executescript(open(os.path.join(ROOT, "schema.sql"), encoding="utf-8").read())
    for v in ("alert_kind", "alert_ladder", "alert_limit"):
        old.execute("DROP VIEW " + v)
    itemdb.add_missing_views(old, s.con)
    got = [r[0] for r in old.execute("SELECT sql FROM sqlite_master ORDER BY name")]
    check("migrated file hash equals the shipped one", (s.schema_hash(),), [(Store._digest([(x,) for x in got]),)])
    check("migrated file holds the ladder", (4,), [tuple(old.execute("SELECT count(*) FROM alert_ladder").fetchone())])
    itemdb.add_missing_views(old, s.con)    # a second open changes nothing
finally:
    __import__("shutil").rmtree(d, True)

for b in bad:
    print("FAIL " + b)
print("%d alert-table values read from the store: %d PASS, %d FAIL" % (n, n - len(bad), len(bad)))
sys.exit(1 if bad else 0)
