"""bd_forms/link.py - the `link` family of bd calls answered from the tickets tables (fleet.db), for bd_compat.py in mode tables.

run(argv, stdin_text) -> (stdout_text, exit_status); raises NotSupported for a form bd-forms.tsv does not record for this family,
and for a recorded form whose answer the tables cannot hold. A link change is one tickets.change row of the dependent ticket,
so the `link` table follows it. Answered: dep add (--type / -t: blocks, parent-child, tracks), dep remove.
Python stdlib only."""
import os, sys, time

HERE = os.path.dirname(os.path.realpath(__file__))
ADAPTERS = os.path.dirname(HERE)
sys.path.insert(0, ADAPTERS)
import tickets  # noqa: E402

FAMILY = "link"
ADDED = {"blocks": "depends on", "parent-child": "is a child of", "tracks": "tracks"}   # the phrase bd prints for each type it was recorded with


class NotSupported(Exception):
    """A form this family does not answer."""


def recorded_forms():
    forms = set()
    for line in open(os.path.join(ADAPTERS, "bd-forms.tsv"), encoding="utf-8"):
        cols = line.rstrip("\n").split("\t")
        if len(cols) >= 3 and cols[2] == FAMILY:
            forms.add(cols[0])
    return forms


def form_of(argv):
    """The form as bd-forms.tsv names it: the verb words, then the sorted flags (bd_compat.py's own rule)."""
    bc = sys.modules["bd_compat"]
    return " ".join(w for w in (bc.verb_of(argv).replace("-", " "), bc.flags_of(argv)) if w)


def split_args(argv):
    """(positional, type): the two ids and the --type / -t value, or None when the flag is absent."""
    pos, typ, i = [], None, 2
    while i < len(argv):
        a = argv[i]
        if a in ("--type", "-t") and i + 1 < len(argv):
            typ, i = argv[i + 1], i + 2
        elif a.startswith("--type="):
            typ, i = a[7:], i + 1
        elif a.startswith("-"):
            raise NotSupported(form_of(argv))
        else:
            pos.append(a)
            i += 1
    if len(pos) != 2:
        raise tickets.Refused("usage: bd dep %s <issue> <depends-on>" % argv[1])
    return pos, typ


def row_of(con, home_id, ident):
    """The ticket as an export row (what tickets.change takes), with its links as dependencies."""
    c = tickets.copy_of(con, home_id, ident)
    if c is None:
        raise tickets.Refused("no issue found matching %r" % ident)
    row = {k: c[k] for k in tickets.FIELDS + ("labels", "metadata", "ephemeral")}
    row["id"] = ident
    row["dependencies"] = c["edges"]
    return row


def label(con, home_id, ident):
    r = con.execute("SELECT title FROM ticket WHERE home = ? AND id = ?", (home_id, ident)).fetchone()
    return "%s (%s)" % (ident, r[0]) if r else ident


def write(st, home_id, verb, row):
    tickets.change(st, int(time.time()), home_id, verb, "bd_compat:%s#%d" % (verb, time.time_ns()), row)


def dep(argv):
    verb = argv[1]
    (frm, to), typ = split_args(argv)
    typ = typ or "blocks"
    if verb == "add" and typ not in ADDED:
        raise NotSupported(form_of(argv))
    h = tickets.home()
    home_id = tickets.itemdb.home_id(h)
    st = tickets.open_tickets(h)
    con = st.con
    con.execute("BEGIN IMMEDIATE")
    try:
        row = row_of(con, home_id, frm)
        edges = row["dependencies"]
        if verb == "add":
            if any(d["depends_on_id"] == to for d in edges):
                raise tickets.Refused("dependency %s -> %s already exists" % (frm, to))
            edges.append(tickets.new_edge(to, typ))
        else:
            if not any(d["depends_on_id"] == to for d in edges):
                raise tickets.Refused("no dependency %s -> %s" % (frm, to))
            row["dependencies"] = [d for d in edges if d["depends_on_id"] != to]
        text = {"add": "✓ Added dependency: %s %s %s (%s)\n" % (label(con, home_id, frm), ADDED.get(typ), label(con, home_id, to), typ),
                "remove": "✓ Removed dependency: %s → %s\n" % (label(con, home_id, frm), label(con, home_id, to))}[verb]
        write(st, home_id, "dep " + verb, row)
        con.execute("COMMIT")
    except Exception:
        con.execute("ROLLBACK")
        raise
    return text, 0


def run(argv, stdin_text):
    if form_of(argv) not in recorded_forms():
        raise NotSupported(form_of(argv))
    if argv[:2] in (["dep", "add"], ["dep", "remove"]):
        return dep(argv)
    raise NotSupported(form_of(argv))
