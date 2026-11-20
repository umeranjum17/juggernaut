"""bd_forms/link.py - the `link` family of bd calls answered from the tickets tables (fleet.db), for bd_compat.py in mode tables.

run(argv, stdin_text) -> (stdout_text, exit_status); raises NotSupported for a form bd-forms.tsv does not record for this family,
and for a recorded form whose answer the tables cannot hold. A link change is one tickets.change row of the dependent ticket,
so the `link` table follows it. Answered: dep add (--type / -t: every type bd accepts), dep remove, and delete <id>... --force:
each ticket is dropped by one change row with no ticket (its links, comments and log go with it); a ticket linked to one of them
is rewritten first, without its edge to it and with each mention of its id in the description as [deleted:<id>], as bd did.
The answer is bd's: the counts of tickets, links, labels and log events removed and of tickets whose text changed; bd counted
events from its own event table, which no export carried, so the tables count the log events they hold.
Python stdlib only."""
import os, re, sys, time

HERE = os.path.dirname(os.path.realpath(__file__))
ADAPTERS = os.path.dirname(HERE)
sys.path.insert(0, ADAPTERS)
import tickets  # noqa: E402

FAMILY = "link"
ADDED = {"blocks": "depends on", "parent-child": "is a child of", "tracks": "tracks",   # the phrase bd prints for each type it accepts
         "related": "is related to", "conditional-blocks": "conditionally depends on", "waits-for": "waits for",
         "discovered-from": "was discovered from", "replies-to": "replies to", "relates-to": "relates to",
         "duplicates": "duplicates", "supersedes": "is superseded by", "authored-by": "was authored by",
         "assigned-to": "is assigned to", "approved-by": "was approved by", "attests": "attests", "caused-by": "was caused by",
         "delegated-from": "was delegated from", "until": "is active until", "validates": "validates"}
ALIAS = {"blocked-by": "blocks", "depends-on": "blocks"}   # bd stores these as blocks


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
    row = {k: c[k] for k in tickets.FIELDS + ("labels", "metadata", "ephemeral", "comments")}   # the change rewrites the comment table
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
    typ = ALIAS.get(typ, typ or "blocks")
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


def delete(argv):
    ids = [a for a in argv[1:] if not a.startswith("-")]
    if not ids or [a for a in argv[1:] if a.startswith("-")] != ["--force"]:
        raise NotSupported(form_of(argv))
    h = tickets.home()
    home_id = tickets.itemdb.home_id(h)
    st = tickets.open_tickets(h)
    con = st.con
    con.execute("BEGIN IMMEDIATE")
    try:
        gone = list(dict.fromkeys(ids))
        for ident in gone:
            row_of(con, home_id, ident)   # refuses a ticket this home does not hold
        marks = ",".join("?" * len(gone))
        links = con.execute("SELECT count(*) FROM link WHERE home = ? AND (from_id IN (%s) OR to_id IN (%s))" % (marks, marks),
                            (home_id, *gone, *gone)).fetchone()[0]
        labels = sum(len(row_of(con, home_id, ident)["labels"]) for ident in gone)
        events = con.execute("SELECT count(*) FROM ticket_event WHERE home = ? AND source = 'event' AND ticket_id IN (%s)" % marks,
                             (home_id, *gone)).fetchone()[0]
        near = [f for (f,) in con.execute(
            "SELECT from_id FROM link WHERE home = ? AND to_id IN (%s) AND from_id NOT IN (%s) UNION "
            "SELECT to_id FROM link WHERE home = ? AND from_id IN (%s) AND to_id NOT IN (%s) ORDER BY 1"
            % (marks, marks, marks, marks), (home_id, *gone, *gone, home_id, *gone, *gone))]
        mention = re.compile(r"(?<![A-Za-z0-9_.-])(%s)(?![A-Za-z0-9_-])" % "|".join(re.escape(i) for i in sorted(gone, key=len, reverse=True)))
        texts = 0
        for ident in near:
            if tickets.copy_of(con, home_id, ident) is None:   # an edge to a ticket another home holds
                continue
            row = row_of(con, home_id, ident)
            edges = [d for d in row["dependencies"] if d["depends_on_id"] not in gone]
            text = mention.sub(r"[deleted:\1]", row.get("description") or "")
            if text != (row.get("description") or ""):
                row["description"], texts = text, texts + 1
            elif edges == row["dependencies"]:
                continue
            row["dependencies"] = edges
            write(st, home_id, "delete", row)
        at, source = int(time.time()), "bd_compat:delete#%d" % time.time_ns()
        for ident in gone:
            con.execute("INSERT INTO ticket_change (at, home, id, verb, source, row) VALUES (?,?,?,?,?,NULL)", (at, home_id, ident, "delete", source))
        con.execute("COMMIT")
    except Exception:
        con.execute("ROLLBACK")
        raise
    return ("✓ Deleted %d issue(s)\n  Removed %d dependency link(s)\n  Removed %d label(s)\n  Removed %d event(s)\n"
            "  Updated text references in %d issue(s)\n" % (len(gone), links, labels, events, texts)), 0


def run(argv, stdin_text):
    if form_of(argv) not in recorded_forms():
        raise NotSupported(form_of(argv))
    if argv[:2] in (["dep", "add"], ["dep", "remove"]):
        return dep(argv)
    if argv[:1] == ["delete"]:
        return delete(argv)
    raise NotSupported(form_of(argv))
