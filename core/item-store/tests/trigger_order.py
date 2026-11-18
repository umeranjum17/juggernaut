"""The trigger order must not matter: load the schema with its triggers in another creation order and rerun the suite.
SQLite promises no firing order between two triggers on one event, so the suite must pass under every order.
Writes scratch files only under ../scratch; prints one line per order."""
import os, re, random, sys
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE if os.path.basename(_HERE) == "item-store" else os.path.dirname(_HERE)
sys.path[:0] = [_ROOT, os.path.join(_ROOT, "tests"), os.path.join(_ROOT, "sim")]
import atexit, shutil, tempfile
TMP = tempfile.mkdtemp(prefix="item-store-")
atexit.register(shutil.rmtree, TMP, True)
import store as item_store, prove as proofs
SQL = open(item_store.SCHEMA, encoding="utf-8").read()
trig = re.findall(r"CREATE TRIGGER \w+.*?END;", SQL, flags=re.S)
rest = SQL
for t in trig:
    rest = rest.replace(t, "", 1)
base = proofs.suite_runner()
def run(order, label):
    path = os.path.join(TMP, "schema-order-%s.sql" % label)
    open(path, "w").write(rest + "\n" + "\n".join(order) + "\n")
    old = item_store.SCHEMA
    item_store.Store.__init__.__defaults__ = (":memory:", path, None, False)
    try:
        fails = proofs.suite_runner()
    finally:
        item_store.Store.__init__.__defaults__ = (":memory:", old, None, False)
        os.unlink(path)
    diff = sorted(set(fails) ^ set(base))
    print("%-10s triggers=%d suite fails=%d differ-from-shipped=%d %s" % (label, len(order), len(fails), len(diff), ",".join(diff[:8])))
    return diff
bad = 0
bad += bool(run(trig, "shipped"))
bad += bool(run(list(reversed(trig)), "reversed"))
for seed in range(8):
    o = list(trig); random.Random(seed).shuffle(o)
    bad += bool(run(o, "shuffle%d" % seed))
print("orders with a different result: %d of 10" % bad)
sys.exit(1 if bad else 0)
