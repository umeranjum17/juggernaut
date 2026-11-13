#!/usr/bin/env python3
"""Word maps: where each word of an older word list lands in a machine (core/machines/README.md, "Word maps")."""
import os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import machine

USAGE = "usage: jg-machine.sh word <map> <list> <word> | replay <map> <corpus> | records <map> <records>"
SPECIAL = {"=": "the state stays as it is", "-": "not a word of this machine", "by-rule": "decided by the rule lines of the map"}


def load_map(name):
    """Parse <maps>/<name>.tsv and refuse a map whose target, wait or health word the machine or the enums lack."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        machine.die(f"jg-machine: '{name}' is not a plain map name")
    mdir = os.environ.get("JG_MACHINES_MAPS") or os.path.join(os.path.dirname(os.environ["JG_MACHINES_TABLES"]), "maps")
    try:
        lines = open(f"{mdir}/{name}.tsv", encoding="utf-8").read().splitlines()
    except OSError as e:
        machine.die(f"jg-machine: no map '{name}': {e.strerror}")
    mp = {"name": name, "enums": {}, "words": {}, "rules": []}
    bad = []
    for ln in lines:
        f = ln.split("\t") + [""] * 9
        if f[0] == "map":
            mp["machine"] = machine.load(f[1])
        elif f[0] == "enum":
            mp["enums"][f[1]] = f[2].split()
        elif f[0] == "word":
            if (f[1], f[2]) in mp["words"]:
                bad.append(f"duplicate word {f[1]} {f[2]}")
            mp["words"][(f[1], f[2])] = dict(zip(("target", "wait", "health"), f[3:6]))
        elif f[0] == "rule":
            mp["rules"].append(dict(zip(("forge", "work", "superseded", "verb", "target", "wait", "health"), f[1:8])))
    if "machine" not in mp:
        bad.append("no map line naming a machine")
    else:
        known = set(mp["machine"]["states"]) | set(mp["machine"]["comp"]) | set(SPECIAL)
        rows = [(f"word {k[0]} {k[1]}", v) for k, v in mp["words"].items()] + [(f"rule {i + 1}", r) for i, r in enumerate(mp["rules"])]
        for what, r in rows:
            bad += [f"{what}: target {t} is not a state of {mp['machine']['name']}" for t in r["target"].split(",") if t not in known]
            for alt in filter(lambda a: a != "-", r["wait"].split("|")):
                w = re.fullmatch(r"([a-z]+)(?: \(([a-z]+)\))?", alt)
                if not w or w[1] not in mp["enums"].get("wait", []) or (w[2] and w[2] not in mp["enums"].get("reason", [])):
                    bad.append(f"{what}: wait {alt} is not in the enums")
            bad += [f"{what}: health {h} is not in the enums" for h in r["health"].split("|") if h != "-" and h not in mp["enums"].get("health", [])]
    for b in bad:
        print(f"lint {name}: {b}")
    if bad:
        sys.exit(1)
    return mp


def say(r):
    print("\t".join((r["target"], r["wait"], r["health"])))


def word(mp, lst, w):
    r = mp["words"].get((lst, w))
    if not r:
        print(f"unmapped {lst} {w}")
        sys.exit(1)
    say(r)


def replay(mp, corpus):
    """Every line is `list<TAB>word`; each must have a target."""
    n = miss = 0
    for ln in open(corpus, encoding="utf-8").read().splitlines():
        f = ln.split("\t")
        if len(f) != 2:
            continue
        n += 1
        if tuple(f) not in mp["words"]:
            miss += 1
            print(f"unmapped {f[0]} {f[1]}")
    print(f"{'fail' if miss else 'ok'} {mp['name']}: {n} words, {miss} unmapped")
    sys.exit(1 if miss else 0)


def rule_for(mp, forge, work, sup, verb):
    for r in mp["rules"]:
        if all(c in ("*", v) for c, v in zip((r["forge"], r["work"], r["superseded"], r["verb"]), (forge, work, sup, verb))):
            return r


def records(mp, path):
    """Each line: task, last verb, forge state, where the work is, superseded, then the target, wait and health it must get."""
    n = bad = 0
    for ln in open(path, encoding="utf-8").read().splitlines():
        f = ln.split("\t")
        if len(f) != 8 or f[0] == "task":
            continue
        n += 1
        r = rule_for(mp, *f[2:5], f[1])
        got = (r["target"], r["wait"], r["health"]) if r else None
        if got != tuple(f[5:8]):
            bad += 1
            print(f"differs {f[0]}: got {got}, want {tuple(f[5:8])}")
    print(f"{'fail' if bad else 'ok'} {mp['name']}: {n} records, {bad} differ")
    sys.exit(1 if bad else 0)


def main(a):
    if len(a) == 4 and a[0] == "word":
        word(load_map(a[1]), a[2], a[3])
    elif len(a) == 3 and a[0] == "replay":
        replay(load_map(a[1]), a[2])
    elif len(a) == 3 and a[0] == "records":
        records(load_map(a[1]), a[2])
    else:
        machine.die(USAGE)


if __name__ == "__main__":
    main(sys.argv[1:])
