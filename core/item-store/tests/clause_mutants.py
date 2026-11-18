#!/usr/bin/env python3
"""Clause-level mutants for schema.sql: remove one refusal clause (one `SELECT RAISE(...) ...;` inside a trigger),
rerun the proof suite's journeys and refusals, and report which cases change. A clause no case notices is either
missing a proof case or redundant with a table constraint. A trigger with a single clause is covered by prove.py's
trigger mutants and skipped here. Writes out/clause-mutants.json; prints one line per clause."""
import json, os, re, sqlite3, sys
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE if os.path.basename(_HERE) == "item-store" else os.path.dirname(_HERE)
sys.path[:0] = [_ROOT, os.path.join(_ROOT, "tests"), os.path.join(_ROOT, "sim")]
import atexit, shutil, tempfile
TMP = tempfile.mkdtemp(prefix="item-store-")
atexit.register(shutil.rmtree, TMP, True)
import prove as proofs, store as item_store

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = TMP
CLAUSE = re.compile(r"\n  SELECT RAISE\(ABORT, '((?:[^']|'')*)'\)[^;]*;")


def main():
    sql = open(item_store.SCHEMA, encoding="utf-8").read()
    base = proofs.suite_runner()
    os.makedirs(SCRATCH, exist_ok=True)
    rows = []
    for m in CLAUSE.finditer(sql):
        msg = m.group(1).replace("''", "'")
        mut = sql[:m.start()] + sql[m.end():]
        try:
            sqlite3.connect(":memory:").executescript(mut.replace("host_now()", "0"))
        except sqlite3.Error:
            continue
        path = os.path.join(SCRATCH, "schema-clause.sql")
        open(path, "w").write(mut)
        old = item_store.Store.__init__.__defaults__
        item_store.Store.__init__.__defaults__ = (":memory:", path, None, False)
        try:
            changed = [c for c in proofs.suite_runner() if c not in base]
        except Exception as e:
            changed = ["crash: " + str(e)[:60]]
        finally:
            item_store.Store.__init__.__defaults__ = old
            os.unlink(path)
        rows.append({"clause": msg, "caught_by": changed})
        print("%-6s %s%s" % ("KILLED" if changed else "ALIVE", msg[:110], ("  <- " + ",".join(changed[:5])) if changed else ""))
    killed = sum(1 for r in rows if r["caught_by"])
    print("\n%d clauses in multi-clause triggers: %d caught by a case, %d not" % (len(rows), killed, len(rows) - killed))
    json.dump({"clauses": len(rows), "killed": killed, "rows": rows}, open(os.path.join(TMP, "clause-mutants.json"), "w"), indent=1)
    return 0 if killed == len(rows) else 1


if __name__ == "__main__":
    sys.exit(main())
