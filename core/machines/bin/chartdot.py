"""One loaded machine table as Graphviz dot, in the notation of section 6.12 (core/machines/README.md, "Diagram").

An initial dot, a ring on a final state, `event [guard]` on each arrow, a box for a composite stage, a dashed outline for a state at rest, and a
dashed cluster for a group. No coordinate is typed: Graphviz places everything, and chartfit.py tries the layout settings below until the
chart passes chartcheck.py. Each arrow carries the id `e<n>_<event>`, so the check can name it.
"""
import re

WIDE, NARROW = "LR", "TB"
# A layout setting: (nodesep, ranksep) for each layout. The search in chartfit.py walks them in this order.
SEPS = {
    WIDE: [(0.28, 0.5), (0.4, 0.7), (0.28, 0.9), (0.5, 0.6), (0.6, 1.0)],
    NARROW: [(0.16, 0.42), (0.25, 0.5), (0.16, 0.6), (0.35, 0.6), (0.25, 0.8), (0.12, 0.5), (0.45, 0.7), (0.2, 1.0)],
}
DEFAULT = {"nodesep": None, "ranksep": None, "margin": 8, "pad": 0, "wrap": 22, "words": 7, "order": None, "ports": False}


def q(x):
    return '"%s"' % x.replace('"', "'")


def wrap(text, width):
    """A guard in words, broken into lines of about `width` letters; Graphviz does not break a label itself."""
    lines, cur = [], ""
    for w in text.split():
        if cur and len(cur) + 1 + len(w) > width:
            lines.append(cur)
            cur = w
        else:
            cur = f"{cur} {w}".strip()
    return lines + [cur] if cur else lines


def short(guard, words=6):
    """The guard on an arrow: its first clause, cut to `words` words. The whole guard stays in the table and in `escalation`."""
    clause = re.split(r"[;,:]", guard)[0].split()
    return " ".join(clause[:words]) + ("\u2026" if len(clause) > words or len(clause) < len(guard.split()) else "")


def label(e, opt):
    pad = " " * opt["pad"]
    lines = [e["event"]] + (["[%s]" % g for g in wrap(short(e["guard"], opt["words"]), opt["wrap"])] if e.get("guard", "") not in ("", "-") and opt["words"] else [])
    return q(pad + " " + (pad + "\\n" + pad).join(lines) + " " + pad)


def members(m, x):
    """The states a name stands for in the picture: a group is each of its members, anything else is itself."""
    return [s for y in m["groups"][x] for s in members(m, y)] if x in m["groups"] else [x]


def nest(m):
    """(parent, sets): the groups Graphviz can draw as clusters. Clusters cannot overlap, so a group that holds the states of a larger group sits
    inside it, and a group that only part overlaps another is not drawn as a cluster (its arrows leave from one of its states)."""
    sets = {g: set(members(m, g)) for g in m["groups"]}
    order = list(sets)
    parent, kept = {}, []
    for g in order:
        sup = [h for h in order if h != g and (sets[g] < sets[h] or sets[g] == sets[h] and order.index(h) < order.index(g))]
        if any(sets[g] & sets[h] and not (sets[g] <= sets[h] or sets[h] <= sets[g]) for h in order if h != g):
            continue
        parent[g] = min(sup, key=lambda h: len(sets[h])) if sup else None
        kept.append(g)
    return {g: parent[g] if parent[g] in kept else None for g in kept}, sets


def cluster(m, g, parent, sets, node, ind, opt):
    kids = [h for h, p in parent.items() if p == g]
    inside = set().union(*[sets[h] for h in kids])
    out = ["%ssubgraph %s {" % (ind, q("cluster_" + g)),
           '%s  label=%s; labeljust="l"; style="rounded,dashed"; class="grp"; margin=%d;' % (ind, q(g), opt["margin"])]
    for h in kids:
        out += cluster(m, h, parent, sets, node, ind + "  ", opt)
    return out + [node(x, ind + "  ") for x in members(m, g) if x not in inside] + ["%s}" % ind]


def dot(m, rankdir, opt=None):
    """The dot text of machine `m` for one layout (WIDE or NARROW) and one setting of the search."""
    opt = dict(DEFAULT, **(opt or {}))
    ns, rs = SEPS[rankdir][0]
    ns, rs = opt["nodesep"] or ns, opt["ranksep"] or rs
    inside = {c for cs in m["comp"].values() for c in cs}  # the states of a composite stage are drawn in the chart of their own table
    states = {k: v for k, v in m["states"].items() if k not in inside}
    states.update(m["stages"])
    L = ["digraph %s {" % q(m["name"]),
         '  rankdir=%s; compound=true; newrank=true; nodesep=%s; ranksep=%s; bgcolor="transparent"; fontname="Helvetica"; fontsize=10;' % (rankdir, ns, rs),
         '  node [shape=box, style="rounded", fontname="Helvetica", fontsize=12, margin="0.10,0.05", height=0.36];',
         '  edge [fontname="Helvetica", fontsize=11, arrowsize=0.7];',
         '  "__init" [shape=circle, style=filled, fillcolor=black, label="", width=0.16, height=0.16, fixedsize=true, class="init"];']

    def node(n, ind="  "):
        s = states[n]
        mode = "w" if s.get("mode") == "waiting" else "r" if s.get("mode") == "rest" else "a"
        if s["kind"] == "terminal":
            return '%s%s [class="kf", label=%s];' % (ind, q(n), q("◎ " + n))
        if s["kind"] == "composite":
            return '%s%s [class="k%s", label=%s];' % (ind, q(n), mode, q(n + "\\n(" + m["subs"][n]["name"] + " inside)"))
        return '%s%s [class="k%s"%s];' % (ind, q(n), mode, ', style="rounded,dashed"' if mode == "r" else "")

    placed = set()
    parent, sets = nest(m)
    for g in [g for g, p in parent.items() if p is None]:
        L += cluster(m, g, parent, sets, node, "  ", opt)
        placed |= sets[g]
    L += [node(n) for n in states if n not in placed]
    anchor = lambda x: members(m, x)[-1]
    first = [e for e in m["rows"] if e["from"] == "(none)"]
    rest = [e for e in m["rows"] if e["from"] != "(none)"]
    loops = {}
    for i, e in enumerate(first + ([rest[i] for i in opt["order"]] if opt["order"] else rest)):
        attrs = "label=%s, id=%s" % (label(e, opt), q("e%d_%s" % (i, re.sub(r"[^A-Za-z0-9-]", "", e["event"]))))
        if opt["ports"] and e["from"] == e["to"]:  # several loops on one state each take their own side, so their labels do not meet
            side = ("ew" if rankdir == NARROW else "ns")[loops.get(e["to"], 0) % 2]
            loops[e["to"]] = loops.get(e["to"], 0) + 1
            attrs += ", tailport=%s, headport=%s" % (side, side)
        if e["from"] == "(none)":
            L.append('  "__init" -> %s [%s];' % (q(e["to"]), attrs))
        elif e["from"] in parent:
            L.append("  %s -> %s [%s, ltail=%s];" % (q(anchor(e["from"])), q(e["to"]), attrs, q("cluster_" + e["from"])))
        elif e["from"] in m["groups"]:
            L.append("  %s -> %s [%s];" % (q(anchor(e["from"])), q(e["to"]), attrs))
        else:
            L.append("  %s -> %s [%s];" % (q(e["from"]), q(e["to"]), attrs))
    if not any(e["from"] == "(none)" for e in m["rows"]):  # a record that lives as long as its home starts in a named state
        L.append('  "__init" -> %s;' % q(next(k for k, s in states.items() if s["kind"] == "initial")))
    return "\n".join(L + ["}"])
