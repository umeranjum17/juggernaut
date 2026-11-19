"""bd_forms/read.py: the `read` family of bd calls, answered from the ticket tables (fleet.db) in mode `tables`.

  run(argv, stdin_text) -> (stdout_text, exit_status)

Verbs: show list ready blocked export epic status gate list comments history --events provenance log types statuses.
Each prints what bd printed for the same store: the keys of an export row in its order, bd's two-space JSON. A form whose
answer needs what the tables do not hold raises NotSupported instead of printing a guess:
  - a ticket with a link: the edge's created_at, created_by and metadata are not kept (link holds from, to, type);
  - a gate row: await_type is not kept; history, events and provenance entries that were never recorded in ticket_event;
  - `schema`, `memories`, `swarm validate`, `q` and `provenance record` (they create or read what no table holds), and text output.
A `show --json` row ends with a Dolt `revision` hash of the row's content: it is not derivable and is not printed.
Python stdlib only."""
import json, os, sys

ADAPTERS = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, ADAPTERS)
import tickets  # noqa: E402
import itemdb  # noqa: E402  (tickets.py put the store folder on the path)

OPEN_STATUSES = ("open", "in_progress", "blocked", "on_hold", "deferred")
COLUMNS = ("id", "title", "description", "status", "priority", "issue_type", "assignee", "created_at", "created_by", "updated_at",
           "started_at", "closed_at", "close_reason", "defer_until", "external_ref", "metadata", "labels", "ephemeral")
TYPES = json.loads('{"core_types":[{"description":"General work item (default)","name":"task"},{"description":"Bug report or defect","name":"bug"},{"description":"New feature or enhancement","name":"feature"},{"description":"Maintenance or housekeeping","name":"chore"},{"description":"Large body of work spanning multiple issues","name":"epic"},{"description":"Architecture decision record (ADR)","name":"decision"},{"description":"Timeboxed investigation to reduce uncertainty before committing to a story","name":"spike"},{"description":"User story describing a feature from the user\'s perspective","name":"story"},{"description":"Marks completion of a set of related issues (contains no work itself)","name":"milestone"}],"schema_version":1,"system_types":[{"description":"Message between agents or users","name":"message"},{"description":"Molecule root for swarm coordination (bd mol)","name":"molecule"},{"description":"Async coordination gate (bd gate, formula gates)","name":"gate"},{"description":"Audit-trail event (bd set-state)","name":"event"}]}')
STATUSES = json.loads('{"built_in_statuses":[{"category":"active","description":"Available to work (default)","icon":"○","name":"open"},{"category":"wip","description":"Actively being worked on","icon":"◐","name":"in_progress"},{"category":"wip","description":"Blocked by a dependency","icon":"●","name":"blocked"},{"category":"frozen","description":"Deliberately put on ice for later","icon":"❄","name":"deferred"},{"category":"done","description":"Completed","icon":"✓","name":"closed"},{"category":"frozen","description":"Persistent, stays open indefinitely","icon":"📌","name":"pinned"},{"category":"wip","description":"Attached to an agent\'s hook","icon":"◇","name":"hooked"}],"custom_statuses":[{"category":"frozen","name":"on_hold"}],"schema_version":1}')


class NotSupported(Exception):
    """A form this module does not answer."""


def dumps(value):
    """bd's JSON: two-space indent, no ASCII escapes, and Go's HTML escapes."""
    text = json.dumps(value, indent=2, ensure_ascii=False)
    return text.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")


def dumps_compact(value):
    text = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    return text.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")


class Flags:
    """The words of one call: the verb's own positional words, valued flags, and switches."""
    VALUED = {"--limit", "--status", "--parent", "--label", "--type", "--updated-after", "-o", "--since"}

    def __init__(self, args):
        self.pos, self.val, self.sw = [], {}, set()
        i = 0
        while i < len(args):
            a = args[i]
            if "=" in a and a.startswith("--") and a.split("=", 1)[0] in self.VALUED:
                self.val[a.split("=", 1)[0]] = a.split("=", 1)[1]
            elif a in self.VALUED and i + 1 < len(args):
                self.val[a] = args[i + 1]
                i += 1
            elif a.startswith("-") and a != "-":
                self.sw.add(a)
            else:
                self.pos.append(a)
            i += 1


class Store:
    def __init__(self):
        h = tickets.home()
        self.con = tickets.open_tickets(h).con
        self.home = itemdb.home_id(h)

    def tickets(self):
        """Every ticket of this home in bd's list order (priority, then newest first), as bd's JSON object."""
        out = []
        for r in self.con.execute("SELECT %s FROM ticket WHERE home = ? ORDER BY priority, created_at DESC, id DESC" % ", ".join(COLUMNS), (self.home,)):
            t = dict(zip(COLUMNS, r))
            t["labels"], t["metadata"] = json.loads(t["labels"]), json.loads(t["metadata"])
            out.append(t)
        return out

    def links(self):
        out = {}
        for f, to, ty in self.con.execute("SELECT from_id, to_id, type FROM link WHERE home = ? ORDER BY from_id, to_id, type", (self.home,)):
            out.setdefault(f, []).append((to, ty))
        return out

    def comments(self, ident):
        return self.con.execute("SELECT id, author, text, created_at FROM comment WHERE home = ? AND ticket_id = ? ORDER BY created_at, id",
                                (self.home, ident)).fetchall()

    def stream(self, ident, source):
        return [json.loads(d) for (d,) in self.con.execute(
            "SELECT data FROM ticket_event WHERE home = ? AND ticket_id = ? AND source = ? ORDER BY n", (self.home, ident, source))]


def export_row(t, store, links, counts, comments, show=False):
    """One ticket as bd exports it. NotSupported when bd would print what the tables do not hold."""
    if links.get(t["id"]):
        raise NotSupported("a link's created_at, created_by and metadata are not kept")
    if t["issue_type"] == "gate":
        raise NotSupported("a gate's await_type is not kept")
    row = {k: t[k] for k in COLUMNS if t[k] not in (None, "") and k not in ("labels", "metadata", "ephemeral")}
    if t["metadata"]:
        row["metadata"] = t["metadata"]
    if t["labels"]:
        row["labels"] = t["labels"]
    if comments.get(t["id"]):
        raise NotSupported("a comment's issue_id is rendered by a form no fixture records")
    blocking = sum(1 for _, ty in links.get(t["id"], []) if ty == "blocks")
    dependents = counts.get(t["id"], 0)
    row["dependent_count" if show else "dependency_count"] = dependents if show else blocking
    row["dependency_count" if show else "dependent_count"] = blocking if show else dependents
    row["comment_count"] = len(comments.get(t["id"], []))
    return row


def context(store):
    links = store.links()
    counts = {}
    for f, edges in links.items():
        for to, ty in edges:
            if ty == "blocks":
                counts[to] = counts.get(to, 0) + 1
    comments = {}
    for ticket_id, in store.con.execute("SELECT ticket_id FROM comment WHERE home = ?", (store.home,)):
        comments.setdefault(ticket_id, []).append(1)
    return links, counts, comments


def parent_of(links, ident):
    return next((to for to, ty in links.get(ident, []) if ty == "parent-child"), None)


def select(store, f, verb):
    """The tickets a list, ready or export call names, in bd's order."""
    links, counts, comments = context(store)
    rows = store.tickets()
    if verb == "ready":
        ready = tickets.ready_ids(store.con, store.home, tickets.now_iso())
        by_id = {t["id"]: t for t in rows}
        rows = [by_id[i] for i in ready]
    elif verb == "list":
        statuses = f.val["--status"].split(",") if "--status" in f.val else None
        if statuses is not None:
            rows = [t for t in rows if t["status"] in statuses]
        elif "--all" not in f.sw:
            rows = [t for t in rows if t["status"] != "closed"]
        if "--include-gates" not in f.sw:
            rows = [t for t in rows if t["issue_type"] != "gate"]
        if "--type" in f.val:
            rows = [t for t in rows if t["issue_type"] == f.val["--type"]]
        if "--updated-after" in f.val:
            rows = [t for t in rows if (t["updated_at"] or "") > f.val["--updated-after"]]
        rows = [t for t in rows if not t["ephemeral"]]
    if "--parent" in f.val:
        rows = [t for t in rows if parent_of(links, t["id"]) == f.val["--parent"]]
    if "--label" in f.val:
        rows = [t for t in rows if f.val["--label"] in t["labels"]]
    limit = int(f.val.get("--limit", 50 if verb != "export" else 0))
    return (rows[:limit] if limit else rows), (links, counts, comments)


def rendered(store, f, verb):
    rows, (links, counts, comments) = select(store, f, verb)
    out = []
    for t in rows:
        row = export_row(t, store, links, counts, comments)
        parent = parent_of(links, t["id"])
        if parent and verb != "export":
            row["parent"] = parent
        out.append(row)
    return out


def list_like(verb, f):
    if "--json" not in f.sw:
        if verb == "list" and not f.pos:
            return "", 2
        raise NotSupported(verb + " without --json")
    return dumps(rendered(Store(), f, verb)) + "\n", 0


def show(f):
    if not f.pos:
        raise NotSupported("show")
    store = Store()
    t = next((t for t in store.tickets() if t["id"] == f.pos[0]), None)
    if t is None:
        sys.stderr.write("Error: no issue found matching %r\n" % f.pos[0])
        return "", 1
    if "--json" not in f.sw:
        raise NotSupported("show without --json")
    if f.sw - {"--json", "--include-dependents", "--brief-deps"}:
        raise NotSupported("show")
    links, counts, comments = context(store)
    return dumps([export_row(t, store, links, counts, comments, show=True)]) + "\n", 0


def export(f):
    text = "".join(dumps_compact(dict({"_type": "issue"}, **row)) + "\n" for row in rendered(Store(), f, "export"))
    if "-o" in f.val:
        with open(f.val["-o"], "w", encoding="utf-8") as fh:
            fh.write(text)
        return "", 0
    return text, 0


def blocked(f):
    store = Store()
    links, _, _ = context(store)
    status = {t["id"]: t["status"] for t in store.tickets()}
    for t in store.tickets():
        if t["status"] != "closed" and any(ty == "blocks" and status.get(to, "closed") != "closed" for to, ty in links.get(t["id"], [])):
            raise NotSupported("blocked: the fields bd adds to a blocked row are not recorded")
    return "[]\n", 0


def epic_status(f):
    store = Store()
    links, counts, comments = context(store)
    out = []
    kids = {}
    for t in store.tickets():
        parent = parent_of(links, t["id"])
        if parent:
            kids.setdefault(parent, []).append(t)
    for t in store.tickets():
        if t["issue_type"] != "epic" or t["status"] == "closed":
            continue
        row = {k: t[k] for k in COLUMNS if t[k] not in (None, "") and k not in ("labels", "metadata", "ephemeral")}
        if t["metadata"]:
            row["metadata"] = t["metadata"]
        if t["labels"]:
            row["labels"] = t["labels"]
        total = len(kids.get(t["id"], []))
        closed = sum(1 for k in kids.get(t["id"], []) if k["status"] == "closed")
        out.append({"epic": row, "total_children": total, "closed_children": closed, "eligible_for_close": bool(total) and total == closed})
    return dumps(out) + "\n", 0


def gate_list(f):
    if any(t["issue_type"] == "gate" and t["status"] != "closed" for t in Store().tickets()):
        raise NotSupported("a gate's await_type is not kept")
    return "null\n", 0


def comments(f):
    if len(f.pos) != 1:
        raise NotSupported("comments")
    rows = Store().comments(f.pos[0])
    if rows or "--json" not in f.sw:
        raise NotSupported("comments: bd's text and JSON for a ticket with comments is not recorded")
    return "[]\n", 0


def stream(verb, f):
    """history --events --json and provenance log --json: the entries ticket_event recorded for the ticket."""
    if "--json" not in f.sw or len(f.pos) < 1:
        raise NotSupported(verb)
    source = "provenance" if verb == "provenance" else "event"
    entries = Store().stream(f.pos[-1], source)
    if not entries:
        raise NotSupported(verb + ": no entries recorded for the ticket")
    return dumps(entries) + "\n", 0


def run(argv, stdin_text):
    verb, args = (argv[0] if argv else ""), [a for a in argv[1:]]
    if verb == "--readonly" and len(argv) > 1:      # bd's global flag in front of the verb
        return run(argv[1:], stdin_text)
    f = Flags(args)
    f.sw.discard("--readonly")
    if verb in ("list", "ready"):
        return list_like(verb, f)
    if verb == "show":
        return show(f)
    if verb == "export":
        return export(f)
    if verb == "blocked":
        return blocked(f)
    if verb == "epic" and f.pos[:1] == ["status"] and "--json" in f.sw:
        return epic_status(f)
    if verb == "gate" and f.pos[:1] == ["list"] and "--json" in f.sw:
        return gate_list(f)
    if verb == "comments":
        return comments(f)
    if verb == "history" and "--events" in f.sw:
        return stream("history", f)
    if verb == "provenance" and f.pos[:1] == ["log"]:
        f.pos = f.pos[1:]
        return stream("provenance", f)
    if verb == "types" and "--json" in f.sw:
        return dumps_sorted(TYPES), 0
    if verb == "statuses" and "--json" in f.sw:
        return dumps_sorted(STATUSES), 0
    raise NotSupported(verb)


def dumps_sorted(value):
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
