#!/usr/bin/env python3
"""Slices 8x and 8y: the store's views carry every value of the former alert table, kept as fixtures/ladder-base.tsv (a copy of the table at
the base of slice 8y, the last commit that held it). Each row is read from the store's views and compared field by field; a row with no store
value fails. The rows jg-alert.sh reads (core/item-store/alertrules.py dump) are compared with the same fixture too.
Also: a file made by the older schema.sql gets the new views by the open-time migration and ends with the shipped rule hash."""
import os, sys, sqlite3
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path[:0] = [ROOT]
from store import Store
import itemdb

TABLE = os.path.join(HERE, "fixtures", "ladder-base.tsv")
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
for r in by("alert"):       # the text of each alert
    check("alert text " + r[1], (r[2], r[6]), q("SELECT fires_on, quiet_when FROM alert_text WHERE alert=?", (r[1],)))
for r in by("rule"):        # rule, id, covers, scope, quieted, why
    check("rule " + r[1], tuple(r[2:6]), q("SELECT covers, scope, quieted, why FROM alert_rule WHERE id=?", (r[1],)))
for r in by("authority"):   # authority, class, ceiling
    check("authority " + r[1], (r[2],), q("SELECT ceiling FROM alert_authority WHERE class=?", (r[1],)))
for r in by("security-source"):
    check("security source " + r[1], (r[1],), q("SELECT source FROM alert_security_source WHERE source=?", (r[1],)))
for name, want in (("alert_text", len(by("alert"))), ("alert_rule", len(by("rule"))), ("alert_authority", len(by("authority"))),
                   ("alert_security_source", len(by("security-source")))):
    check("no extra rows in " + name, (want,), q("SELECT count(*) FROM " + name))
# what jg-alert.sh reads: the dump, kind by kind, equals the fixture (a limit row keeps its seconds; its why is not read)
import alertrules
for kind in ("alert", "rule", "ladder", "limit", "authority", "security-source"):
    want = [r[1:3] if kind == "limit" else r[1:] for r in by(kind)]
    want = [list(r) for r in want]
    check("alertrules " + kind, want, [alertrules.rows(kind)])
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
    for v in ("alert_kind", "alert_ladder", "alert_limit", "alert_text", "alert_rule", "alert_authority", "alert_security_source"):
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
print("%d ladder values read from the store: %d PASS, %d FAIL" % (n, n - len(bad), len(bad)))
sys.exit(1 if bad else 0)
