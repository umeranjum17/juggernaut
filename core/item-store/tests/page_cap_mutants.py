#!/usr/bin/env python3
"""Each part of the page read (item_store.Store.pages) is needed: remove the row cap, the byte cap, or the cursor in turn
and proof case A16 must fail. Prints one line per mutant."""
import contextlib, io, os, sys
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE if os.path.basename(_HERE) == "item-store" else os.path.dirname(_HERE)
sys.path[:0] = [_ROOT, os.path.join(_ROOT, "tests"), os.path.join(_ROOT, "sim")]
import atexit, shutil, tempfile
TMP = tempfile.mkdtemp(prefix="item-store-")
atexit.register(shutil.rmtree, TMP, True)
import store as item_store, prove as proofs

orig = item_store.Store.pages
def no_cursor(self, reader, rows=item_store.PAGE_ROWS, size=item_store.PAGE_BYTES):
    c = self.con.execute("SELECT seq FROM cursor WHERE reader=?", (reader,)).fetchone()
    self.con.execute("DELETE FROM cursor WHERE reader=?", (reader,))
    try:
        return orig(self, reader, rows, size)
    finally:
        if c: self.con.execute("INSERT INTO cursor VALUES(?, ?)", (reader, c[0]))
mutants = [("no row cap", dict(defaults=(10 ** 9, item_store.PAGE_BYTES))),
           ("no byte cap", dict(defaults=(item_store.PAGE_ROWS, 10 ** 12))),
           ("no cursor (every read starts at seq 0)", dict(fn=no_cursor))]
caught = 0
for name, m in mutants:
    keep = (item_store.Store.pages, item_store.Store.pages.__defaults__)
    if "fn" in m: item_store.Store.pages = m["fn"]
    else: item_store.Store.pages.__defaults__ = m["defaults"]
    proofs.RES, proofs.FAILS = [], []
    with contextlib.redirect_stdout(io.StringIO()):
        proofs.reads()
    item_store.Store.pages = keep[0]; item_store.Store.pages.__defaults__ = keep[1]
    caught += bool(proofs.FAILS)
    print("%s: %s" % (name, "A16 fails (caught)" if proofs.FAILS else "A16 passes (NOT caught)"))
print("%d of %d page-read mutants caught" % (caught, len(mutants)))
sys.exit(0 if caught == len(mutants) else 1)
