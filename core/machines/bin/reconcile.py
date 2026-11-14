"""Reconcile a machine table with the traffic its writers made (core/machines/README.md, "Reconcile").

The traffic is the shadow log (an illegal move, one line each) and, for the ticket machine, the move log (a legal move). Each observed
edge, a `from` state and an event, gets its count, its writer and a verdict: `legal` (the table has the edge), `settled` (a writer
repeated a move the ticket already made, so jg-move.sh writes nothing), `history` (no writer makes it today), or `UNNAMED`, a real
edge the table calls illegal and no defect names. The defect names live in core/machines/maps/<machine>-traffic.tsv."""
import os, sys

VERDICTS = ("settled", "history")


def traffic_path(m):
    return os.path.join(os.path.dirname(m["tdir"].rstrip("/")), "maps", f"{m['name']}-traffic.tsv")


def load_traffic(m):
    """The named defects of one machine: {(from, event): (verdict, name, why)}. A row that names a state or an event the table lacks is refused."""
    path, rows, bad = traffic_path(m), {}, []
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return rows
    events = {e["event"] for e in m["edges"]}
    for n, ln in enumerate(lines, 1):
        if not ln.strip() or ln.startswith("#"):
            continue
        f = ln.split("\t") + [""] * 5
        verdict, frm, event, name, why = f[:5]
        if verdict not in VERDICTS or frm not in m["states"] or event not in events or not name or not why:
            bad.append(f"{path}:{n}: a row is verdict ({'|'.join(VERDICTS)}), a state of {m['name']}, one of its events, a name and why")
        elif (frm, event) in rows:
            bad.append(f"{path}:{n}: {frm} {event} is named twice")
        else:
            rows[(frm, event)] = (verdict, name, why)
    if bad:
        print("\n".join(bad), file=sys.stderr)
        sys.exit(1)
    return rows


def settled(m, frm, event):
    """Exit 0 and print the name when a writer's move `event` from `frm` is a repeat of a move already made; else exit 1."""
    hit = load_traffic(m).get((frm, event))
    if hit and hit[0] == "settled":
        print(hit[1])
        sys.exit(0)
    sys.exit(1)


def observed(m, shadow, moves):
    """Count each (from, event) edge of the machine in the two logs: {(from, event): {"shadow": n, "moves": n}}."""
    seen = {}
    for path, kind, col in ((shadow, "shadow", 1), (moves, "moves", None)):
        try:
            lines = open(path, encoding="utf-8").read().splitlines() if path else []
        except OSError:
            lines = []
        for ln in lines:
            f = ln.split("\t")
            if kind == "shadow" and len(f) >= 4 and f[1] == m["name"]:
                key = (f[2], f[3])
            elif kind == "moves" and m["name"] == "ticket" and len(f) >= 5:  # <epoch> <ticket id> <from> <event> <to>
                key = (f[2], f[3])
            else:
                continue
            seen.setdefault(key, {"shadow": 0, "moves": 0})[kind] += 1
    return seen


def reconcile(m, shadow, moves):
    """Print one line per observed edge and a count line; exit 1 when a real edge is UNNAMED."""
    named, seen, legal = load_traffic(m), observed(m, shadow, moves), {(e["from"], e["event"]): e for e in m["edges"]}
    by_event = {}
    for e in m["edges"] + m["rows"]:
        by_event.setdefault(e["event"], e["writer"])
    print("from\tevent\tcount\tshadow\tmoves\twriter\tverdict\tname")
    unnamed = lines = 0
    for (frm, event), n in sorted(seen.items(), key=lambda kv: -(kv[1]["shadow"] + kv[1]["moves"])):
        total = n["shadow"] + n["moves"]
        lines += total
        if (frm, event) in legal:
            verdict, name = "legal", legal[(frm, event)]["guard"]
        elif (frm, event) in named:
            verdict, name = named[(frm, event)][0], named[(frm, event)][1]
        else:
            verdict, name, unnamed = "UNNAMED", "no edge and no named defect", unnamed + 1
        print(f"{frm}\t{event}\t{total}\t{n['shadow']}\t{n['moves']}\t{by_event.get(event, '-')}\t{verdict}\t{name}")
    print(f"{'fail' if unnamed else 'ok'} reconcile {m['name']}: {len(seen)} edges, {lines} lines, {unnamed} unnamed")
    sys.exit(1 if unnamed else 0)
