#!/usr/bin/env python3
"""The clock-leap rule switched off (the tick never sees the steady clock), on the simulator's seeds: the invariants
must catch it, and the run counts the early climbs that the rule prevents.
Usage: clock_mutant.py [first-last seeds, default 0-19]"""
import sys, os, json
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE if os.path.basename(_HERE) == "item-store" else os.path.dirname(_HERE)
sys.path[:0] = [_ROOT, os.path.join(_ROOT, "tests"), os.path.join(_ROOT, "sim")]
import atexit, shutil, tempfile
TMP = tempfile.mkdtemp(prefix="item-store-")
atexit.register(shutil.rmtree, TMP, True)
import sim as simulator, store as item_store
orig = item_store.Store.tick
item_store.Store.tick = lambda self, at, steady=None: orig(self, at)
lo, _, hi = (sys.argv[1] if len(sys.argv) > 1 else "0-19").partition("-")
res = [simulator.Sim(sd, 24, True).run() for sd in range(int(lo), int(hi) + 1)]
fails = [r for r in res if not r["ok"]]
kinds = {}
for r in fails:
    k = r["why"].split(": ", 1)[1].split(" ", 1)[0]
    kinds[k] = kinds.get(k, 0) + 1
print(json.dumps({"seeds": len(res), "caught": len(fails), "by_invariant": kinds,
                  "early_climbs_before_first_failure": sum(r["early_climbs"] for r in res),
                  "early_climbs_to_owner": sum(r["early_climbs_to_owner"] for r in res)}))
