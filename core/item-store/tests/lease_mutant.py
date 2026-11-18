#!/usr/bin/env python3
"""The tick lease taken away the old way (the tick runs in Main's home only, so a Squad Lead home's tick never runs),
on the simulator's seeds with the watcher-stop fault: the invariants must catch it (I14: while Main's watcher is
stopped, Main-down never reaches the owner).
Usage: lease_mutant.py [first-last seeds, default 0-4]"""
import sys, os, json
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = _HERE if os.path.basename(_HERE) == "item-store" else os.path.dirname(_HERE)
sys.path[:0] = [_ROOT, os.path.join(_ROOT, "tests"), os.path.join(_ROOT, "sim")]
import atexit, shutil, tempfile
TMP = tempfile.mkdtemp(prefix="item-store-")
atexit.register(shutil.rmtree, TMP, True)
import sim as simulator
orig = simulator.Sim.tick


def main_home_only(self, runner="main"):
    if runner == "lead":
        self.at(self.t + 60, self.tick, runner)
        return simulator.SKIP
    return orig(self, runner)


simulator.Sim.tick = main_home_only
lo, _, hi = (sys.argv[1] if len(sys.argv) > 1 else "0-4").partition("-")
res = [simulator.Sim(sd, 24, True).run() for sd in range(int(lo), int(hi or lo) + 1)]
fails = [r for r in res if not r["ok"]]
kinds = {}
for r in fails:
    k = r["why"].split(": ", 1)[1].split(" ", 1)[0]
    kinds[k] = kinds.get(k, 0) + 1
print(json.dumps({"seeds": len(res), "caught": len(fails), "by_invariant": kinds,
                  "watcher_stops": sum(r["watcher-stop"] for r in res)}))
