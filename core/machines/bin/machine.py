#!/usr/bin/env python3
"""Machine tables: the state of a record and its legal moves, read from one TSV table (core/machines/README.md)."""
import os, re, subprocess, sys

USAGE = "usage: jg-machine.sh show|next <machine> <id> | check <machine> [--corpus <file>] | coverage|diagram|events <machine> | edge-check <machine> <from> <to>"


def die(msg, rc=2):
    print(msg, file=sys.stderr)
    sys.exit(rc)


def leaves(m, x):
    """The states a table name stands for: a composite stage is each state inside it, a group is its members, a state is itself."""
    if x in m["comp"]:
        return [(c, True) for c in m["comp"][x]]
    if x in m["groups"]:
        return [p for y in m["groups"][x] for p in leaves(m, y)]
    return [(x, False)]


def entry(m, x):
    """Where a move that names a composite stage lands: the initial state of the table inside it."""
    return next(c for c in m["comp"][x] if m["states"][c]["kind"] == "entry") if x in m["comp"] else x


def load(name, depth=0):
    """Parse <tables>/<name>.tsv and refuse a table that breaks a lint rule, naming each defect."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name) or depth > 2:
        die(f"jg-machine: '{name}' is not a plain machine name")
    tdir = os.environ["JG_MACHINES_TABLES"]
    try:
        lines = open(f"{tdir}/{name}.tsv", encoding="utf-8").read().splitlines()
    except OSError as e:
        die(f"jg-machine: no table for machine '{name}': {e.strerror}")
    m = {"name": name, "tdir": tdir, "states": {}, "edges": [], "observer": None, "rows": [], "groups": {}, "comp": {}, "subs": {}, "stages": {}}
    bad, inner = [], []
    for ln in lines:
        f = ln.split("\t") + [""] * 8
        if f[0] == "state":
            if f[1] in m["states"]:
                bad.append(f"duplicate state {f[1]}")
            m["states"][f[1]] = {"kind": f[2], "sentence": f[3], "requires": f[4]}
        elif f[0] == "edge":
            m["rows"].append(dict(zip(("from", "event", "to", "writer", "command", "guard", "test"), f[1:8])))
        elif f[0] == "group":
            m["groups"][f[1]] = " ".join(f[2:]).split()
        elif f[0] == "inner":
            inner.append((f[1], f[2]))
        elif f[0] == "observer":
            m["observer"] = f[1]
    for stage, sub_name in inner:  # a composite stage holds the states of another table, named <stage>.<state>
        if m["states"].get(stage, {}).get("kind") != "composite":
            bad.append(f"inner {stage} is not a composite state")
            continue
        sub = load(sub_name, depth + 1)
        m["subs"][stage] = sub
        m["stages"][stage] = m["states"].pop(stage)
        m["comp"][stage] = [f"{stage}.{k}" for k in sub["states"]]
        for k, s in sub["states"].items():
            m["states"][f"{stage}.{k}"] = dict(s, kind="entry" if s["kind"] == "initial" else s["kind"])
        m["edges"] += [dict(e, **{"from": f"{stage}.{e['from']}", "to": f"{stage}.{e['to']}"}) for e in sub["edges"]]
    for k, s in list(m["states"].items()):
        if s["kind"] == "composite":
            bad.append(f"composite state {k} has no inner table")
            del m["states"][k]
    st = m["states"]
    for e in m["rows"]:
        to = entry(m, e["to"])
        if e["from"] == "(none)":
            if st.get(to, {}).get("kind") != "initial":
                bad.append(f"entry event {e['event']} does not lead to the initial state")
            continue
        for frm, via in leaves(m, e["from"]):
            m["edges"].append(dict(e, **{"from": frm, "to": to, "via": via}))
    if not any(s["kind"] == "initial" for s in st.values()):
        bad.append("no initial state")
    if not m["observer"]:
        bad.append("no observer")
    seen, reach = set(), [k for k, s in st.items() if s["kind"] == "initial"]
    for e in m["edges"]:
        if e["from"] not in st or e["to"] not in st:
            bad.append(f"edge {e['from']} {e['event']} names a state the table lacks")
        if (e["from"], e["event"]) in seen:
            bad.append(f"duplicate edge {e['from']} {e['event']}")
        seen.add((e["from"], e["event"]))
        if e["writer"] in ("", "-"):
            bad.append(f"edge {e['from']} {e['event']} has no writer")
        if st.get(e["from"], {}).get("kind") == "terminal" and not e.get("via"):
            bad.append(f"terminal state {e['from']} has an exit edge")
    for k in reach:  # reachability: walk the edges from every initial state
        reach += [e["to"] for e in m["edges"] if e["from"] == k and e["to"] not in reach]
    for k, s in st.items():
        if k not in reach:
            bad.append(f"unreachable state {k}")
        if not s["sentence"].strip():
            bad.append(f"state {k} has no captain sentence")
    for b in bad:
        print(f"lint {name}: {b}")
    if bad:
        sys.exit(1)
    return m


def observe(m, rid):
    """Run the table's observer (an existing reader) for one id and return its state word."""
    if not re.fullmatch(r"[A-Za-z0-9._:@-]+", rid):
        die(f"jg-machine: '{rid}' is not a plain record id")
    out = subprocess.run(["bash", "-c", m["observer"], m["name"], rid], capture_output=True, text=True, timeout=30).stdout
    word = out.strip()
    if word not in m["states"]:
        die(f"{m['name']} {rid}: no state: the observer printed '{word}'", 1)
    return word


def check(m, corpus):
    base = set()
    try:
        for ln in open(f"{m['tdir']}/known-baseline.tsv", encoding="utf-8").read().splitlines():
            if ln.startswith(m["name"] + "\t"):
                base.add(ln.split("\t", 1)[1])
    except OSError:
        pass
    moves = {(e["from"], e["event"], e["to"]) for e in m["edges"]}
    n = findings = 0
    for ln in (open(corpus, encoding="utf-8").read().splitlines() if corpus else []):
        if not ln.strip():
            continue
        n, f, why = n + 1, ln.split("\t"), None
        if len(f) == 1 and f[0] not in m["states"]:
            why = f"{f[0]} is not a state"
        elif len(f) == 3 and tuple(f) not in moves:
            why = f"{' '.join(f)} is not a move"
        elif len(f) not in (1, 3):
            why = "is not a state or a from/event/to move"
        if why and ln in base:
            print(f"baseline {m['name']} corpus:{n}: {' '.join(f)}")
        elif why:
            findings += 1
            print(f"bad {m['name']} corpus:{n}: {why}")
    if corpus:
        print(f"{'fail' if findings else 'ok'} {m['name']}: {n} lines, {findings} findings")
    else:
        print(f"ok {m['name']}: {len(m['states'])} states, {len(m['rows'])} edges")
    sys.exit(1 if findings else 0)


def coverage(m):
    """An edge with no test id (empty or '-') is untested."""
    bad = [e for e in m["rows"] if e["test"] in ("", "-")]
    for e in bad:
        print(f"untested {m['name']} {e['from']} {e['event']} {e['to']}")
    print(f"{'fail' if bad else 'ok'} {m['name']}: {len(m['rows'])} edges, {len(bad)} untested")
    sys.exit(1 if bad else 0)


def border(m, x):
    """The boxes an arrow leaves from: a composite stage is one box, a group is each of its members."""
    return [b for y in m["groups"][x] for b in border(m, y)] if x in m["groups"] else [x]


def diagram_body(m, pad):
    """The lines of a Mermaid state diagram for one table: a composite stage holds the diagram of the table inside it."""
    first = {e["to"]: e["event"] for e in m["rows"] if e["from"] == "(none)"}
    out = []
    for k, s in m["states"].items():
        if s["kind"] == "initial":
            out.append(f"{pad}[*] --> {k}" + (f": {first[k]}" if k in first else ""))
    for stage, sub in m["subs"].items():
        out += [f"{pad}state {stage} {{"] + diagram_body(sub, pad + "  ") + [f"{pad}}}"]
    for e in m["rows"]:
        if e["from"] == "(none)":
            continue
        for frm in border(m, e["from"]):
            out.append(f"{pad}{frm} --> {e['to']}: {e['event']}")
    out += [f"{pad}{k} --> [*]" for k, s in m["states"].items() if s["kind"] == "terminal" and not any(k in c for c in m["comp"].values())]
    return out


def diagram(m):
    """Mermaid state diagram, generated from the table and never hand-drawn."""
    print("\n".join(["stateDiagram-v2"] + diagram_body(m, "  ")))


def events(m):
    """The events a table declares, one per line: event, from, to (a group or a stage as written)."""
    for e in m["rows"]:
        print(f"{e['event']}\t{e['from']}\t{e['to']}")


def edge_check(m, frm, to):
    """Read-only answer for a writer: is the move from -> to legal? Exit 0 legal, 1 not."""
    to = entry(m, to)
    for x in (frm, to):
        if x not in m["states"]:
            die(f"{m['name']}: {x} is not a state", 1)
    hit = [e for e in m["edges"] if e["from"] == frm and e["to"] == to]
    for e in hit:
        print(f"legal {m['name']} {frm} {to}\t{e['event']}\t{e['writer']}")
    if not hit:
        print(f"illegal {m['name']} {frm} {to}")
    sys.exit(0 if hit else 1)


def main(a):
    if len(a) == 2 and a[0] == "check":
        check(load(a[1]), None)
    if len(a) == 4 and a[0] == "check" and a[2] == "--corpus":
        check(load(a[1]), a[3])
    if len(a) == 2 and a[0] in ("coverage", "diagram", "events"):
        {"coverage": coverage, "diagram": diagram, "events": events}[a[0]](load(a[1]))
        return
    if len(a) == 4 and a[0] == "edge-check":
        edge_check(load(a[1]), a[2], a[3])
    if len(a) != 3 or a[0] not in ("show", "next"):
        die(USAGE)
    m = load(a[1])
    word = observe(m, a[2])
    s = m["states"][word]
    print(f"machine\t{m['name']}\nid\t{a[2]}\nstate\t{word}")
    if a[0] == "show":
        print(f"kind\t{s['kind']}\nsentence\t{s['sentence']}\nrequires\t{s['requires']}")
        return
    out = [e for e in m["edges"] if e["from"] == word]
    print(f"moves\t{len(out)}")
    for e in out:
        print("\t".join(("move", e["event"], e["to"], e["writer"], e["command"].replace("{id}", a[2]), e["guard"])))


if __name__ == "__main__":
    main(sys.argv[1:])
