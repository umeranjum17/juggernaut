#!/usr/bin/env python3
"""jg-beads-read.py - the read facts the ticket adapter needs from this home's tickets tables.

Usage: jg-beads-read.py rev <id>...
       jg-beads-read.py list [--after <id>] [--limit <1-500>]
       jg-beads-read.py show <id>...
       jg-beads-read.py board <closed-since|--all>
       jg-beads-read.py history <id>
       jg-beads-read.py landings

It only reads, and every verb answers from the ticket tables of JG_HOME's item store, opened read-only.
rev prints one `<id><TAB><rev>` line per id; a missing id is refused. A row's `revision` is the seq of its last ticket_change, which an edge
write to another row does not move, so rev is a 16-hex digest of that revision with the labels, the edges both ways and the comment count.
Compare it for equality only.
list walks the rows with a cursor: one JSON object `{"rows": [...], "next": <id or null>}`, rows in id order, every row as show gives it.
Closed rows and gates are left out, and `--after` takes the previous page's `next`.
show prints a JSON array of the named rows, each with its `rev`; a missing id exits 4, and a page of list that cannot be shown exits 5,
so a caller can tell a ticket that is not there, and a list that would be short, from a store that cannot be read.
board prints a JSON array of every row the fleet board can show: each open row and each row closed at or after <closed-since> (a UTC `YYYY-MM-DDTHH:MM:SSZ`),
gates left out, in id order, in one query. Each row has the shape and the `rev` that `show` gives it, so a ticket read here and read again with `show`
carries the same rev. With --all, that same query includes older closed rows for ticket maintenance and card reconciliation.
history prints one line per change that altered the row, newest first, `<source><TAB><date><TAB><kind><TAB><changed columns>`, from ticket_change.
landings reads task/commit pairs as TSV on stdin and prints matching land events in input order as task, commit, ready time (or -),
event time and payload JSON. Tickets and events are read from one snapshot for the whole batch.
"""
import hashlib
import json
import os
import re
import sqlite3
import sys
import datetime

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
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


class Tables(sqlite3.Connection):
    home = "main"   # whose tickets these reads name


def table_store(missing_ok=False):
    """The tickets tables of the one item store, opened read-only."""
    sys.path.insert(0, os.path.join(HERE, "..", "core", "item-store"))
    import itemdb
    home = os.environ.get("JG_HOME") or os.path.join(HERE, "..")
    path = itemdb.db_path(home)
    if not os.path.exists(path):
        if missing_ok:
            return None
        die("there is no item store at %s" % path)
    con = sqlite3.connect("file:%s?mode=ro" % path, uri=True, factory=Tables)
    con.row_factory = sqlite3.Row
    con.home = itemdb.home_id(home)
    return con


def utc(epoch):
    return datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc)


def stamp(value):
    """A stored time in the board's form (UTC, whole seconds, a Z), or None."""
    if not value:
        return None
    when = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    return when.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def table_ids(con, after, limit):
    return [r[0] for r in con.execute("select id from ticket where home = ? and status <> 'closed' and issue_type <> 'gate' and ephemeral = 0 and id > ? order by id limit ?",
                                      (con.home, after, limit + 1))]


def table_parts(con, since, ids=None):
    """What board_query's one SELECT gives, as the same tagged objects, from ticket, link and ticket_change. The tables keep no comments, so no `comments` part;
    the revision is the seq of the ticket's last change and updated_at its time. With ids, those rows alone, gates included."""
    shown = {}
    which = ("t.id in (%s)" % ",".join("?" * len(ids))) if ids else "t.issue_type <> 'gate' and t.ephemeral = 0"
    for r in con.execute("select t.*, (select max(seq) from ticket_change c where c.home = t.home and c.id = t.id) as seq,"
                         " (select at from ticket_change c where c.home = t.home and c.id = t.id order by seq desc limit 1) as last"
                         " from ticket t where t.home = ? and " + which + " order by t.id", (con.home, *(ids or ()))):
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
    than the change before it: [ticket, kind, time, tool, model, effort, kind], a missing word as NULL, as the board prints it."""
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


def table_rows(con, since=None, ids=None):
    """The rows table_parts names, each in the shape `show` prints, with its rev, in id order."""
    parts = table_parts(con, since, ids)
    rows = {p["id"]: dict(p, labels=[], dependencies=[], dependents=[], comment_count=0) for p in parts if p["t"] == "row"}
    for p in parts:
        if p["t"] == "label" and p["id"] in rows:
            rows[p["id"]]["labels"].append(p["label"])
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
    return out


def show(ids, fail_code=None):
    rows = table_rows(table_store(), ids=ids)
    missing = [i for i in ids if i not in {r["id"] for r in rows}]
    if missing:
        die("no such ticket: %s" % ", ".join(missing), fail_code or 4)
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
    ids = table_ids(con, after, limit)
    more = len(ids) > limit
    ids = ids[:limit]
    rows = show(ids, 5) if ids else []
    rows.sort(key=lambda r: r["id"])
    print(json.dumps({"rows": rows, "next": ids[-1] if more else None}))


def cmd_show(args):
    if not args:
        die("usage: show <id>...")
    print(json.dumps(show([ident(a) for a in args])))


def cmd_board(args):
    if len(args) != 1 or args[0] != '--all' and not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", args[0]):
        die("usage: board <closed-since as YYYY-MM-DDTHH:MM:SSZ|--all>")
    since = None if args[0] == '--all' else args[0].replace("T", " ").rstrip("Z")
    print(json.dumps(table_rows(table_store(), since)))


def cmd_history(args):
    if len(args) != 1:
        die("usage: history <id>")
    row = ident(args[0])
    con = table_store()
    found = table_history(con, row)
    if not found:
        die("no history for %s" % row, 1)
    for cell in found:
        print("\t".join(cell))


def cmd_landings(args):
    if args:
        die("usage: landings (read task<TAB>commit pairs on stdin)")
    requested = [line.rstrip("\n").split("\t") for line in sys.stdin]
    if not requested:
        return
    if any(len(pair) != 2 or not all(pair) for pair in requested):
        die("landings input needs one task<TAB>commit pair per line")
    con = table_store(missing_ok=True)
    if con is None:
        return
    con.execute("BEGIN")
    by_id, by_task = {}, {}
    first = "(SELECT CASE c.verb WHEN 'import' THEN c.seq ELSE -c.seq END FROM ticket_change c WHERE c.home = t.home AND c.id = t.id ORDER BY c.seq LIMIT 1)"
    for row in con.execute(
            "SELECT id, issue_type, ephemeral, json_extract(metadata, '$.task'), json_extract(metadata, '$.ready_at')"
            " FROM ticket t WHERE home = ? ORDER BY priority, created_at DESC, " + first + ", id DESC", (con.home,)):
        ticket, kind, ephemeral, task, ready = row
        by_id[ticket] = (ticket, ready if isinstance(ready, str) and ready else "-")
        if isinstance(task, str) and task and kind != "gate" and not ephemeral:
            by_task.setdefault(task, by_id[ticket])
    for task, commit in requested:
        row = by_id.get(task) or by_task.get(task)
        if row is None:
            continue
        ticket, ready = row
        event = con.execute(
            "SELECT json_extract(data, '$.occurred_at'), data FROM ticket_event"
            " WHERE home = ? AND ticket_id = ? AND source = 'provenance' AND kind = 'land' AND ref_kind = 'git-sha' AND ref = ?"
            " ORDER BY json_extract(data, '$.occurred_at') DESC, n LIMIT 1", (con.home, ticket, commit)).fetchone()
        if event is None or event[0] is None:
            continue
        occurred_at, data = event
        payload = json.loads(data).get("payload")
        if isinstance(payload, str) and payload:
            payload = json.loads(payload)
        print("\t".join((task, commit, ready, occurred_at, json.dumps(payload, sort_keys=True))))


def main(argv):
    verbs = {"rev": cmd_rev, "list": cmd_list, "show": cmd_show, "board": cmd_board, "history": cmd_history, "landings": cmd_landings}
    if not argv or argv[0] not in verbs:
        die("usage: jg-beads-read.py <%s> ..." % "|".join(verbs))
    verbs[argv[0]](argv[1:])


if __name__ == "__main__":
    main(sys.argv[1:])
