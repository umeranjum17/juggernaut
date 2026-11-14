#!/usr/bin/env python3
"""Machine tables: the state of a record and its legal moves, read from one TSV table (core/machines/README.md)."""
import os, re, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import alerttable
import chartfit
import reconcile
import tablelint

USAGE = "usage: jg-machine.sh show|next <machine> <id> | enum <name> | legal <enum> <value> | write <enum> <value> <file> | check <machine> [--corpus <file>] | coverage|events|writers|escalation <machine> | chart-check <svg>... | diagram <machine> [--out <dir>] [--dot wide|narrow | --mermaid] [--tries N] | edge-check <machine> <from> <to> | reconcile <machine> [--shadow <file>] [--moves <file>] | settled <machine> <state> <event>"


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


def load_enum(name):
    """Read <enums>/<name>.states, the closed list of one machine's states: value, mark, [kind,] meaning. Returns (values, defects)."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        die(f"jg-machine: '{name}' is not a plain enum name")
    edir = os.environ.get("JG_MACHINES_ENUMS") or os.path.dirname(os.environ["JG_MACHINES_TABLES"].rstrip("/"))
    try:
        lines = open(f"{edir}/{name}.states", encoding="utf-8").read().splitlines()
    except OSError as e:
        die(f"jg-machine: no enum '{name}': {e.strerror}")
    vals, bad, width = {}, [], None
    for n, ln in enumerate(lines, 1):
        if not ln.strip() or ln.startswith("#"):
            continue
        f = ln.split("\t")
        width = width or len(f)
        if len(f) != width or width not in (3, 4):
            bad.append(f"line {n}: want value, mark, [kind,] meaning in {width or 3}-4 tab-separated columns, got {len(f)}")
            continue
        v, mark, kind, meaning = (f[0], f[1], f[2] if width == 4 else None, f[-1])
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", v):
            bad.append(f"line {n}: value '{v}' is not a plain word")
        if v in vals:
            bad.append(f"line {n}: duplicate value {v}")
        if mark not in ("initial", "final", "-"):
            bad.append(f"value {v}: mark '{mark}' is not initial, final or -")
        if kind is not None and kind not in ("active", "waiting", "rest", "final"):
            bad.append(f"value {v}: kind '{kind}' is not active, waiting, rest or final")
        if kind is not None and (mark == "final") != (kind == "final"):
            bad.append(f"value {v}: mark {mark} and kind {kind} disagree about being final")
        if not meaning.strip():
            bad.append(f"value {v} has no meaning")
        vals[v] = {"mark": mark, "kind": kind, "meaning": meaning}
    init = [v for v, x in vals.items() if x["mark"] == "initial"]
    if len(init) > 1:
        bad.append(f"{len(init)} initial values ({' '.join(init)}), at most one")
    if width == 4 and not init:
        bad.append("no initial value")
    if not vals:
        bad.append("no values")
    return vals, bad


def check_enum(name):
    vals, bad = load_enum(name)
    for b in bad:
        print(f"lint enum {name}: {b}")
    if bad:
        sys.exit(1)
    return vals


def load(name, depth=0):
    """Parse <tables>/<name>.tsv and refuse a table that breaks a lint rule, naming each defect."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name) or depth > 2:
        die(f"jg-machine: '{name}' is not a plain machine name")
    tdir = os.environ["JG_MACHINES_TABLES"]
    try:
        lines = open(f"{tdir}/{name}.tsv", encoding="utf-8").read().splitlines()
    except OSError as e:
        die(f"jg-machine: no table for machine '{name}': {e.strerror}")
    enum = next((ln.split("\t")[1] for ln in lines if ln.startswith("enum\t")), None)  # opt in: the closed list this table's states come from
    m = {"enum": enum, "name": name, "tdir": tdir, "states": {}, "edges": [], "observer": None, "rows": [], "groups": {}, "comp": {}, "subs": {}, "stages": {}, "open": {}}
    bad, inner = [], []
    for ln in lines:
        f = ln.split("\t") + [""] * 9
        if f[0] == "state":
            if f[1] in m["states"]:
                bad.append(f"duplicate state {f[1]}")
            m["states"][f[1]] = {"kind": f[2], "sentence": f[3], "requires": f[4], "mode": f[5], "limit": f[6], "emits": f[7], "alert": f[8]}
        elif f[0] == "edge":
            m["rows"].append(dict(zip(("from", "event", "to", "writer", "command", "guard", "test"), f[1:8])))
        elif f[0] == "group":
            m["groups"][f[1]] = " ".join(f[2:]).split()
        elif f[0] == "inner":
            inner.append((f[1], f[2]))
        elif f[0] == "open":
            m["open"][f[1]] = f[2]
        elif f[0] == "observer":
            m["observer"] = f[1]
    if enum:
        legal = check_enum(enum)
        bad += [f"state {k} is not in enum {enum} (legal: {' '.join(legal)})" for k in m["states"] if k not in legal]
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
    bad += tablelint.lint(m)
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
        hint = f"; legal: {' '.join(check_enum(m['enum']))}" if m["enum"] else ""
        die(f"{m['name']} {rid}: no state: the observer printed '{word}'{hint}", 1)
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


def writers(m):
    """Report mode: list each edge whose writer file does not report its move; exit 0 whatever it finds."""
    root = os.environ.get("JG_MACHINES_ROOT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
    silent = tablelint.silent_writers(m, root)
    for ln in silent:
        print(ln)
    print(f"report {m['name']}: {len(m['rows'])} edges, {len(silent)} silent")


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


def mermaid(m):
    """The Mermaid text of the table, for the page of the ticket machine in docs/ (GitHub draws it); the drawn charts are Graphviz."""
    print("\n".join(["stateDiagram-v2"] + diagram_body(m, "  ")))


def diagram_files(m, out, tries):
    """Draw both layouts into `out` (<machine>-LR.svg and -TB.svg, with the dot text of the try that won) and check each; exit 1 on a fault."""
    os.makedirs(out, exist_ok=True)
    failed = 0
    for rankdir, tag in ((chartfit.chartdot.WIDE, "LR"), (chartfit.chartdot.NARROW, "TB")):
        svg, bad, n = chartfit.fit(m, rankdir, tries)
        with open(f"{out}/{m['name']}-{tag}.svg", "w", encoding="utf-8") as f:
            f.write(svg)
        w = re.search(r'<svg width="(\d+)pt" height="(\d+)pt"', svg)
        print(f"{'fail' if bad else 'ok'} {m['name']}-{tag}.svg\t{w.group(1)}pt x {w.group(2)}pt\t{len(m['rows'])} arrows\ttry {n}")
        for b in bad:
            print(f"  chart {m['name']}-{tag}: {b}")
        failed += bool(bad)
    sys.exit(1 if failed else 0)


def diagram(m, args):
    """The command: `diagram <machine> [--out <dir>] [--tries N]` draws and checks; `--dot wide|narrow` prints the dot text of the first try."""
    out, tries, dot, i = None, 144, None, 0
    if args == ["--mermaid"]:
        return mermaid(m)
    while i < len(args):
        if args[i] == "--out" and i + 1 < len(args):
            out, i = args[i + 1], i + 2
        elif args[i] == "--tries" and i + 1 < len(args) and args[i + 1].isdigit():
            tries, i = int(args[i + 1]), i + 2
        elif args[i] == "--dot" and i + 1 < len(args) and args[i + 1] in ("wide", "narrow"):
            dot, i = args[i + 1], i + 2
        else:
            die(USAGE)
    if dot:
        print(chartfit.chartdot.dot(m, chartfit.chartdot.WIDE if dot == "wide" else chartfit.chartdot.NARROW))
        return
    try:
        diagram_files(m, out or os.path.join(os.getcwd(), "charts"), tries)
    except chartfit.NoRenderer as e:
        die(f"jg-machine: {e}", 1)


def chart_check(files):
    """The chart check alone, on SVG files Graphviz made and chartcheck.plate lifted the labels of; a file named *-TB.svg is a narrow layout."""
    failed = 0
    for f in files:
        try:
            bad = chartfit.chartcheck.check(open(f, encoding="utf-8").read(), f.endswith("-TB.svg"))
        except OSError as e:
            die(f"jg-machine: cannot read {f}: {e.strerror}")
        print(f"{'fail' if bad else 'ok'} {os.path.basename(f)}")
        for b in bad:
            print(f"  chart {os.path.basename(f)}: {b}")
        failed += bool(bad)
    sys.exit(1 if failed else 0)


def escalation(m):
    """For each state: its mode, what it emits and to which machine, its timeout, its alert, and who is told first, next, and by a board card."""
    print("state\tmode\temits\ttimeout\talert\ttold first\ttold next\tboard card")
    for k, s in m["states"].items():
        al = alerttable.of(s)
        first, nxt, card = alerttable.chain(al) if al else ("-", "-", "-")
        print("\t".join([k, tablelint.mode(s), s.get("emits") or "-", s.get("limit") or "-", al or "-", first, nxt, card]))


def events(m):
    """The events a table declares, one per line: event, from, to (a group or a stage as written)."""
    for e in m["rows"]:
        print(f"{e['event']}\t{e['from']}\t{e['to']}")


def edge_check(m, frm, to):
    """Read-only answer for a writer: is the move from -> to legal? Exit 0 legal, 1 not."""
    to = entry(m, to)
    for x in (frm, to):
        if x not in m["states"] and not (x == frm == "(none)"):  # (none) is the start of a record's first move
            die(f"{m['name']}: {x} is not a state", 1)
    hit = [e for e in (m["rows"] if frm == "(none)" else m["edges"]) if e["from"] == frm and entry(m, e["to"]) == to]
    for e in hit:
        print(f"legal {m['name']} {frm} {to}\t{e['event']}\t{e['writer']}")
    if not hit:
        print(f"illegal {m['name']} {frm} {to}")
    sys.exit(0 if hit else 1)


def legal(name, value):
    """The enum reader for a write: the value if the closed list has it, else exit 1 with the legal values."""
    vals = check_enum(name)
    if value not in vals:
        die(f"jg-machine: refused: '{value}' is not a value of enum {name}; legal: {' '.join(vals)}", 1)
    return value


def main(a):
    if len(a) == 3 and a[0] == "legal":
        print(legal(a[1], a[2]))
        return
    if len(a) == 4 and a[0] == "write":  # the one writer of a state word to a file: it writes nothing for an illegal value
        value = legal(a[1], a[2])
        with open(a[3], "w", encoding="utf-8") as f:
            f.write(value + "\n")
        return
    if len(a) == 2 and a[0] == "check":
        check(load(a[1]), None)
    if len(a) == 4 and a[0] == "check" and a[2] == "--corpus":
        check(load(a[1]), a[3])
    if len(a) == 2 and a[0] == "enum":
        vals = check_enum(a[1])
        print(f"ok enum {a[1]}: {len(vals)} values")
        return
    if len(a) >= 2 and a[0] == "chart-check":
        chart_check(a[1:])
        return
    if len(a) >= 2 and a[0] == "diagram":
        diagram(load(a[1]), a[2:])
        return
    if len(a) == 2 and a[0] in ("coverage", "events", "writers", "escalation"):
        {"coverage": coverage, "events": events, "writers": writers, "escalation": escalation}[a[0]](load(a[1]))
        return
    if len(a) == 4 and a[0] == "settled":
        reconcile.settled(load(a[1]), a[2], a[3])
    if len(a) >= 2 and a[0] == "reconcile":
        opt = dict(zip(a[2::2], a[3::2]))
        home = os.environ.get("JG_HOME") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
        data = os.environ.get("JG_DATA_OVERRIDE") or os.path.join(home, "data")
        if len(a) % 2 or set(opt) - {"--shadow", "--moves"}:
            die(USAGE)
        reconcile.reconcile(load(a[1]), opt.get("--shadow", f"{data}/machine-shadow.log"), opt.get("--moves", f"{data}/moves.log"))
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
