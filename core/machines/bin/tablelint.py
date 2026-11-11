"""The statechart rule of section 6.12 for one loaded machine table (core/machines/README.md, "Lint").

A state has a mode: active (something works), waiting (someone owes a move, with a timeout), rest (nobody owes a move, with the event
that wakes it) or final. A state line may carry the mode and its limit as its sixth and seventh columns, and an `open` line (state or `*`, then the reason) says that a
state has no move out yet, so it is not a dead end; with no mode, a terminal state
is final and every other state is active. load() in machine.py calls lint() once the edges are expanded and prints each defect it returns.
"""
import re

MODES = ("active", "waiting", "rest", "final")
TIMEOUT = re.compile(r"\d+[smhd] -> (alert [a-z0-9-]+|[a-z0-9-]+)")


def mode(s):
    """The mode of a state: the one it names, else final for a terminal state and active for the rest."""
    return s.get("mode") or ("final" if s["kind"] == "terminal" else "active")


def words(x):
    """A sentence or a command, reduced to the words that decide whether two of them say the same thing."""
    return re.sub(r"[^a-z0-9]+", " ", x.lower()).strip()


def lint(m):
    """Return one line for each defect of the table's states and events that the basic lint of load() does not already name."""
    st, edges, bad = m["states"], m["edges"], []
    firsts = [e["event"] for e in m["rows"] if e["from"] == "(none)"]
    if len(firsts) > 1:
        bad.append(f"two first events: {', '.join(firsts)}")
    starts = [k for k, s in st.items() if s["kind"] == "initial"]
    if len(starts) > 1:
        bad.append(f"more than one initial state: {', '.join(starts)}")
    for e in m["rows"]:
        if e["event"] in ("", "-"):
            bad.append(f"an event with no name from {e['from']} to {e['to']}")
    targets = {}
    for e in edges:
        targets.setdefault((e["from"], e["event"]), set()).add(e["to"])
    for (frm, ev), to in targets.items():
        if len(to) > 1:
            bad.append(f"event {ev} from {frm} has two targets: {', '.join(sorted(to))}")
    for k, s in st.items():
        out = {e["event"] for e in edges if e["from"] == k}
        md, limit = mode(s), s.get("limit", "")
        entry_actions = {words(e["command"]) for e in edges if e["to"] == k and e["command"] not in ("", "-")}
        if md not in MODES:
            bad.append(f"state {k} has the unknown mode {md}")
        elif (md == "final") != (s["kind"] == "terminal"):
            bad.append(f"state {k} has the mode {md} and the kind {s['kind']}")
        if md == "waiting":
            nxt = limit.split(" -> ", 1)[-1]
            if not TIMEOUT.fullmatch(limit) or not (nxt.startswith("alert ") or nxt in out):
                bad.append(f"waiting state {k} has no timeout that names an alert or a next move")
        if md == "rest" and limit not in out:
            bad.append(f"rest state {k} names no wake event")
        if words(s["sentence"]) in entry_actions:
            bad.append(f"state {k} has its entry action as its meaning")
        if s["kind"] != "terminal" and not out and not m["open"].get(k, m["open"].get("*")):
            bad.append(f"dead end {k} is not final")
    return bad
