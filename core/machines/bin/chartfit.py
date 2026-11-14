"""Draw one machine with Graphviz and search layout settings until the chart passes the check (core/machines/README.md, "Diagram").

A try is a setting of chartdot.dot: the spacing of the layout, the margin of a cluster, the padding and wrap of a label, and, late in the
search, the order of the arrows, which decides how Graphviz breaks ties. The tries run in a fixed order with a fixed shuffle, so the same table
gives the same bytes. The renderer is render-dot.cjs; a missing @viz-js/viz stops the command with the pinned install line.
"""
import json
import os
import subprocess

import chartcheck
import chartdot

HERE = os.path.dirname(os.path.abspath(__file__))
BATCH = 8


class NoRenderer(Exception):
    pass


def pin():
    """The install spec of the renderer, read from the `viz` row of toolchain.versions."""
    root = os.environ.get("JG_PIN_FILE_OVERRIDE") or os.path.join(HERE, "..", "..", "..", "toolchain.versions")
    try:
        for ln in open(root, encoding="utf-8"):
            f = ln.split()
            if len(f) >= 2 and f[0] == "viz":
                return f[1]
    except OSError:
        pass
    return "@viz-js/viz"


def render(dots):
    """The SVG text of each dot text, one process for the batch."""
    r = subprocess.run(["node", os.path.join(HERE, "render-dot.cjs")], input=json.dumps(dots), capture_output=True, text=True)
    if r.returncode == 3 or (r.returncode != 0 and "no @viz-js/viz" in r.stderr):
        raise NoRenderer(f"the diagram command needs Graphviz through {pin()}: npm install -g {pin()} (or set JG_VIZ_DIR to a folder that holds it)")
    if r.returncode != 0:
        raise NoRenderer(f"the renderer failed: {r.stderr.strip()[:300]}")
    out = json.loads(r.stdout)
    return out["svg"], out["errors"]


FORMATS = {chartdot.WIDE: [(22, 7), (30, 8), (16, 6)], chartdot.NARROW: [(22, 7), (16, 6), (14, 5), (12, 4), (12, 3), (10, 2)]}  # (letters a line of a guard, words of it)


def tries(m, rankdir, n):
    """The n settings to try, in order. The label format changes slowest, then the arrow order, then the spacing."""
    seps, forms, nrows = chartdot.SEPS[rankdir], FORMATS[rankdir], len([e for e in m["rows"] if e["from"] != "(none)"])
    seed, out = 11, []
    for t in range(n):
        ns, rs = seps[t % len(seps)]
        step, form = t // len(seps) % 3, t // (len(seps) * 3) % len(forms)
        opt = {"nodesep": ns, "ranksep": rs, "margin": 14 if step == 1 else 8, "pad": 0, "wrap": forms[form][0], "words": forms[form][1], "order": None, "ports": step == 2}
        if step == 2:
            order = list(range(nrows))
            for i in range(nrows - 1, 0, -1):
                seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
                j = seed % (i + 1)
                order[i], order[j] = order[j], order[i]
            opt["order"] = order
        out.append(opt)
    return out


def fit(m, rankdir, n=144):
    """(svg, defects, number of tries) of the first try that passes, else of the try with the fewest defects."""
    best, done = None, 0
    opts = tries(m, rankdir, n)
    for i in range(0, n, BATCH):
        batch = opts[i:i + BATCH]
        svgs, errs = render([chartdot.dot(m, rankdir, o) for o in batch])
        for o, svg, err in zip(batch, svgs, errs):
            done += 1
            if svg is None:
                raise NoRenderer(f"Graphviz refused the chart of {m['name']}: {err}")
            svg = chartcheck.plate(svg)
            bad = chartcheck.check(svg, rankdir == chartdot.NARROW)
            if not bad:
                return svg, [], done
            if best is None or len(bad) < len(best[1]):
                best = (svg, bad, done)
    return best[0], best[1], done
