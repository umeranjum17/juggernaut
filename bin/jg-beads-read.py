#!/usr/bin/env python3
"""jg-beads-read.py - the read facts the ticket adapter needs from a Beads store, each proved in data/ta-j1-beads-facts/facts.md.

Usage: BEADS_DIR=<store>/.beads jg-beads-read.py rev <id>...
       BEADS_DIR=<store>/.beads jg-beads-read.py list [--after <id>] [--limit <1-500>]
       BEADS_DIR=<store>/.beads jg-beads-read.py show <id>...
       BEADS_DIR=<store>/.beads jg-beads-read.py board <closed-since|--all>
       BEADS_DIR=<store>/.beads jg-beads-read.py history <id>

It only reads, and every call goes through bin/jg-beads.sh (JG_BEADS_SH names another wrapper), never bd or dolt directly.
rev prints one `<id><TAB><rev>` line per id; a missing id is refused. bd's own `revision` moves on every write to the row but not on a
label, dependency, parent or comment write, so rev is a 16-hex digest of that revision with the labels, the edges both ways and the
comment count. Compare it for equality only.
list walks the store with a cursor: one JSON object `{"rows": [...], "next": <id or null>}`, rows in id order, every row as `bd show --json`
gives it plus its `rev`. Closed rows and gates are left out, as `bd list` leaves them out, and `--after` takes the previous page's `next`.
show prints a JSON array of the rows as `bd show --json` gives them, each with its `rev`; a missing id exits 4, and a page of list that cannot be shown exits 5,
so a caller can tell a ticket that is not there, and a list that would be short, from a store that cannot be read.
board prints a JSON array of every row the fleet board can show: each open row and each row closed at or after <closed-since> (a UTC `YYYY-MM-DDTHH:MM:SSZ`),
gates left out, in id order. Each row has the shape and the `rev` that `show` gives it, so a ticket read here and read again with `show` carries the same rev,
but one dolt query reads the whole store, because `bd list` and `bd show` open the store once per call and took minutes on a store of thousands of rows.
With --all, that same query includes older closed rows for ticket maintenance and card reconciliation.
history prints one line per commit that changed the row, newest first, `<commit><TAB><date><TAB><kind><TAB><changed columns>`, from
dolt_diff_issues: `bd history` lists every commit of the store, so it is not used.
"""
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import datetime

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
WRAPPER = os.environ.get("JG_BEADS_SH") or os.path.join(HERE, "jg-beads.sh")
IDENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
MAX_PAGE = 500
DEFAULT_PAGE = 50


def die(message, code=2):
    sys.stderr.write("jg-beads-read: %s\n" % message)
    sys.exit(code)


def ident(value):
    if not IDENT.match(value):
        die("not a ticket id: %r" % value)
    return value


def run(args, fail_code=None, absent=None):
    """The wrapper's stdout. A failure whose output contains `absent` is a ticket that is not there, so it returns "[]" for show to name."""
    done = subprocess.run([WRAPPER] + args, capture_output=True, text=True)
    if done.returncode != 0 and absent and absent in done.stdout + done.stderr:
        return "[]"
    if done.returncode != 0:
        die("%s failed (%d): %s" % (" ".join(args[:2]), done.returncode, done.stderr.strip() or done.stdout.strip()), fail_code or done.returncode)
    return done.stdout


def sql(query):
    """The rows of one SELECT as lists of cells, header dropped."""
    lines = [l for l in run(["dolt", "sql", "-q", query]).splitlines() if l.startswith("| ")]
    return [[c.strip() for c in l[2:-2].split(" | ")] for l in lines[1:]]


class Tables(sqlite3.Connection):
    home = "main"   # whose tickets these reads name


def table_store():
    """The tickets tables of the one item store, opened read-only, when <main home>/config/bd-tables exists; else None (every question then goes to dolt)."""
    sys.path.insert(0, os.path.join(HERE, "..", "core", "item-store"))
    import itemdb
    home = os.environ.get("JG_HOME") or os.path.join(HERE, "..")
    if not os.path.exists(os.path.join(itemdb.main_home(home), "config", "bd-tables")):
        return None
    path = itemdb.db_path(home)
    if not os.path.exists(path):
        die("config/bd-tables is set but there is no item store at %s" % path)
    con = sqlite3.connect("file:%s?mode=ro" % path, uri=True, factory=Tables)
    con.row_factory = sqlite3.Row
    con.home = itemdb.home_id(home)
    return con


def utc(epoch):
    return datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc)


def stamp(value):
    """A stored time in dolt's own board form (UTC, whole seconds, a Z), or None."""
    if not value:
        return None
    when = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    return when.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def table_ids(con, after, limit):
    return [r[0] for r in con.execute("select id from ticket where home = ? and status <> 'closed' and issue_type <> 'gate' and ephemeral = 0 and id > ? order by id limit ?",
                                      (con.home, after, limit + 1))]


def table_parts(con, since):
    """What board_query's one SELECT gives, as the same tagged objects, from ticket, link and ticket_change. The tables keep no comments, so no `comments` part;
    the revision is the seq of the ticket's last change and updated_at its time."""
    shown = {}
    for r in con.execute("select t.*, (select max(seq) from ticket_change c where c.home = t.home and c.id = t.id) as seq,"
                         " (select at from ticket_change c where c.home = t.home and c.id = t.id order by seq desc limit 1) as last"
                         " from ticket t where t.home = ? and t.issue_type <> 'gate' and t.ephemeral = 0 order by t.id", (con.home,)):
        closed = stamp(r["closed_at"])
        if since is None or r["status"] != "closed" or (closed or "") >= since.replace(" ", "T") + "Z":
            shown[r["id"]] = r
    parts = []
    for r in shown.values():
        parts.append({"t": "row", "id": r["id"], "title": r["title"], "description": r["description"], "status": r["status"], "issue_type": r["issue_type"],
                      "assignee": r["assignee"], "priority": r["priority"], "external_ref": r["external_ref"], "defer_until": stamp(r["defer_until"]),
                      "created_at": stamp(r["created_at"]), "updated_at": utc(r["last"]).strftime("%Y-%m-%dT%H:%M:%SZ"), "closed_at": stamp(r["closed_at"]),
                      "metadata": json.loads(r["metadata"]), "revision": str(r["seq"])})
        parts += [{"t": "label", "id": r["id"], "label": label} for label in json.loads(r["labels"])]
    for r in con.execute("select l.from_id, l.to_id, l.type, x.status, x.issue_type from link l left join ticket x on x.home = l.home and x.id = l.to_id where l.home = ?", (con.home,)):
        parts.append({"t": "edge", "from": r[0], "to": r[1], "type": r[2], "status": r[3], "issue_type": r[4]})
    return parts


def table_history(con, row):
    """history's lines from ticket_change: one per change that altered the row, newest first, `<source><TAB><time><TAB><kind><TAB><changed fields>`."""
    out, before = [], None
    for c in con.execute("select seq, at, source, row, links from ticket_change where home = ? and id = ? order by seq", (con.home, row)):
        now = json.loads(c["row"]) if c["row"] else None
        if now is not None:
            now["links"] = c["links"]
        kind = "removed" if now is None else "modified" if before is not None else "added"
        names = sorted(k for k in (now or before or {}) if (now or {}).get(k) != (before or {}).get(k) and (now or before or {}).get(k) not in (None, ""))
        if names or kind != "modified":
            out.append([c["source"], utc(c["at"]).strftime("%Y-%m-%d %H:%M:%S"), kind, ",".join(names)])
        before = now
    return out[::-1]


def table_starts(con):
    """incarnations' cells from ticket_change: the claims and handoffs of each ticket, as a start is each change that names another tool, model or effort
    than the change before it: [ticket, kind, time, tool, model, effort, kind], a missing word as NULL, as dolt prints it."""
    cells, was = [], {}
    for c in con.execute("select at, id, row from ticket_change where home = ? and row is not null order by seq", (con.home,)):
        meta = json.loads(json.loads(c["row"]).get("metadata") or "{}")
        named = tuple(meta.get(k) for k in ("agent", "model", "effort"))
        if any(named) and named != was.get(c["id"]):
            cells.append([c["id"], "handoff" if c["id"] in was else "claim", utc(c["at"]).strftime("%Y-%m-%d %H:%M:%S"),
                          *[v or "NULL" for v in named], meta.get("kind") or "NULL"])
            was[c["id"]] = named
    return cells


def rev_of(row):
    edges = lambda key: sorted((e["id"], e.get("dependency_type", "")) for e in row.get(key) or [])
    parts = [row.get("revision"), sorted(row.get("labels") or []), edges("dependencies"), edges("dependents"), row.get("comment_count", 0)]
    return hashlib.sha256(json.dumps(parts, sort_keys=True).encode()).hexdigest()[:16]


def show(ids, fail_code=None):
    rows = json.loads(run(["show"] + ids + ["--json", "--include-dependents", "--brief-deps"], fail_code, "not found") or "[]")
    found = {r["id"]: r for r in rows}
    missing = [i for i in ids if i not in found]
    if missing:
        die("no such ticket: %s" % ", ".join(missing), fail_code or 4)
    for r in rows:
        r["rev"] = rev_of(r)
    return rows


def cmd_rev(args):
    if not args:
        die("usage: rev <id>...")
    for r in show([ident(a) for a in args]):
        print("%s\t%s" % (r["id"], r["rev"]))


def cmd_list(args):
    after, limit = "", DEFAULT_PAGE
    while args:
        flag, args = args[0], args[1:]
        if flag not in ("--after", "--limit") or not args:
            die("usage: list [--after <id>] [--limit <1-%d>]" % MAX_PAGE)
        value, args = args[0], args[1:]
        if flag == "--after":
            after = ident(value) if value else ""
        elif value.isdigit() and 1 <= int(value) <= MAX_PAGE:
            limit = int(value)
        else:
            die("--limit must be a whole number from 1 to %d" % MAX_PAGE)
    con = table_store()
    ids = table_ids(con, after, limit) if con else [r[0] for r in sql("select id from issues where status <> 'closed' and issue_type <> 'gate' and id > '%s' order by id limit %d" % (after, limit + 1))]
    more = len(ids) > limit
    ids = ids[:limit]
    rows = show(ids, 5) if ids else []
    rows.sort(key=lambda r: r["id"])
    print(json.dumps({"rows": rows, "next": ids[-1] if more else None}))


def cmd_show(args):
    if not args:
        die("usage: show <id>...")
    print(json.dumps(show([ident(a) for a in args])))


def board_query(since):
    """One SELECT whose every line is one JSON object tagged `t`: a row, a label, an edge (with the far end's status and type) or a comment count."""
    stamp = lambda column: "date_format(%s, '%%Y-%%m-%%dT%%H:%%i:%%sZ')" % column
    far = "coalesce(d.depends_on_issue_id, d.depends_on_wisp_id, d.depends_on_external)"  # the far end is a row, a wisp or a name; bd shows all three as an edge
    shown = "i.issue_type <> 'gate'"
    if since is not None: shown += " and (i.status <> 'closed' or i.closed_at >= '%s')" % since
    return (
        "select json_object('t', 'row', 'id', i.id, 'title', i.title, 'description', i.description, 'status', i.status, 'issue_type', i.issue_type,"
        " 'assignee', i.assignee, 'priority', i.priority, 'external_ref', i.external_ref, 'defer_until', %s,"
        " 'created_at', %s, 'updated_at', %s, 'closed_at', %s, 'metadata', i.metadata, 'revision', cast(i.row_lock as char))"
        " from issues i where %s"
        " union all select json_object('t', 'label', 'id', l.issue_id, 'label', l.label) from labels l join issues i on i.id = l.issue_id where %s"
        " union all select json_object('t', 'edge', 'from', d.issue_id, 'to', %s, 'type', d.type, 'status', x.status, 'issue_type', x.issue_type)"
        " from dependencies d left join issues x on x.id = %s"
        " union all select json_object('t', 'comments', 'id', issue_id, 'n', count(*)) from comments group by issue_id"
    ) % (stamp("i.defer_until"), stamp("i.created_at"), stamp("i.updated_at"), stamp("i.closed_at"), shown, shown, far, far)


def cmd_board(args):
    if len(args) != 1 or args[0] != '--all' and not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", args[0]):
        die("usage: board <closed-since as YYYY-MM-DDTHH:MM:SSZ|--all>")
    since = None if args[0] == '--all' else args[0].replace("T", " ").rstrip("Z")
    con = table_store()
    if con:
        parts = table_parts(con, since)
    else:
        lines = [l for l in run(["dolt", "sql", "-q", board_query(since)]).splitlines() if l.startswith("| ")]
        parts = [json.loads(l[2:-2]) for l in lines[1:]]  # one column: a " | " inside a description is not a cell break
    rows = {p["id"]: dict(p, labels=[], dependencies=[], dependents=[], comment_count=0) for p in parts if p["t"] == "row"}
    for p in parts:
        if p["t"] == "label" and p["id"] in rows:
            rows[p["id"]]["labels"].append(p["label"])
        elif p["t"] == "comments" and p["id"] in rows:
            rows[p["id"]]["comment_count"] = p["n"]
        elif p["t"] == "edge":
            if p["from"] in rows:
                rows[p["from"]]["dependencies"].append({"id": p["to"], "status": p["status"], "issue_type": p["issue_type"], "dependency_type": p["type"]})
                if p["type"] == "parent-child":
                    rows[p["from"]]["parent"] = p["to"]
            if p["to"] in rows:
                rows[p["to"]]["dependents"].append({"id": p["from"], "dependency_type": p["type"]})
    out = []
    for key in sorted(rows):
        row = rows[key]
        row.pop("t")
        if row.get("closed_at") is None:
            row.pop("closed_at", None)
        row["labels"].sort()
        row["rev"] = rev_of(row)
        out.append(row)
    print(json.dumps(out))


def cmd_history(args):
    if len(args) != 1:
        die("usage: history <id>")
    row = ident(args[0])
    con = table_store()
    found = table_history(con, row) if con else dolt_history(row)
    if not found:
        die("no history for %s" % row, 1)
    for cell in found:
        print("\t".join(cell))


def dolt_history(row):
    cols = [c[0] for c in sql("select column_name from information_schema.columns where table_name = 'issues' order by ordinal_position")]
    cols = [c for c in cols if c != "id"]
    changed = ", ".join("not (from_%s <=> to_%s)" % (c, c) for c in cols)
    query = ("select coalesce(to_commit, from_commit), coalesce(to_commit_date, from_commit_date), diff_type, %s from dolt_diff_issues "
             "where to_id = '%s' or from_id = '%s' order by coalesce(to_commit_date, from_commit_date) desc, diff_type" % (changed, row, row))
    return [[cell[0], cell[1], cell[2], ",".join(c for c, flag in zip(cols, cell[3:]) if flag == "1")] for cell in sql(query)]


def main(argv):
    verbs = {"rev": cmd_rev, "list": cmd_list, "show": cmd_show, "board": cmd_board, "history": cmd_history}
    if not argv or argv[0] not in verbs:
        die("usage: jg-beads-read.py <%s> ..." % "|".join(verbs))
    verbs[argv[0]](argv[1:])


if __name__ == "__main__":
    main(sys.argv[1:])
