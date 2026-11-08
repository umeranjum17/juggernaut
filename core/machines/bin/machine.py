#!/usr/bin/env python3
"""Machine tables: the state of a record and its legal moves, read from one TSV table (core/machines/README.md)."""
import os, re, subprocess, sys

USAGE = "usage: jg-machine.sh show|next <machine> <id> | check <machine> [--corpus <file>]"


def die(msg, rc=2):
    print(msg, file=sys.stderr)
    sys.exit(rc)


def load(name):
    """Parse <tables>/<name>.tsv and refuse a table that breaks a lint rule, naming each defect."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        die(f"jg-machine: '{name}' is not a plain machine name")
    tdir = os.environ["JG_MACHINES_TABLES"]
    try:
        lines = open(f"{tdir}/{name}.tsv", encoding="utf-8").read().splitlines()
    except OSError as e:
        die(f"jg-machine: no table for machine '{name}': {e.strerror}")
    m = {"name": name, "tdir": tdir, "states": {}, "edges": [], "observer": None}
    bad = []
    for ln in lines:
        f = ln.split("\t") + [""] * 8
        if f[0] == "state":
            if f[1] in m["states"]:
                bad.append(f"duplicate state {f[1]}")
            m["states"][f[1]] = {"kind": f[2], "sentence": f[3], "requires": f[4]}
        elif f[0] == "edge":
            m["edges"].append(dict(zip(("from", "event", "to", "writer", "command", "guard", "test"), f[1:8])))
        elif f[0] == "observer":
            m["observer"] = f[1]
    st = m["states"]
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
        if st.get(e["from"], {}).get("kind") == "terminal":
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
        print(f"ok {m['name']}: {len(m['states'])} states, {len(m['edges'])} edges")
    sys.exit(1 if findings else 0)


def main(a):
    if len(a) == 2 and a[0] == "check":
        check(load(a[1]), None)
    if len(a) == 4 and a[0] == "check" and a[2] == "--corpus":
        check(load(a[1]), a[3])
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


main(sys.argv[1:])
