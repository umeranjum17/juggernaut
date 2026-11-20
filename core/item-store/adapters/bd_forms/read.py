"""bd_forms/read.py: the `read` family of bd calls, answered from the ticket tables (fleet.db) in mode `tables`.

  run(argv, stdin_text) -> (stdout_text, exit_status)

Verbs: show list ready blocked export epic status gate list comments history --events provenance log types statuses.
Each prints what bd printed for the same store: the keys of an export row in its order, bd's two-space JSON. A form whose
answer needs what the tables do not hold raises NotSupported instead of printing a guess:
  - a `show` row whose edge points at a ticket this home does not hold, or a linked row with --include-dependents or --brief-deps: bd's form is not recorded;
  - `comments` of a text other than one plain line of at most 60 characters, or of several comments: bd renders the text through a markdown renderer;
  - a gate row: await_type is not kept; history, events and provenance entries that were never recorded in ticket_event;
  - `schema`, `memories`, `swarm validate`, `q` and `provenance record` (they create or read what no table holds), and text output.
A `show --json` row ends with a Dolt `revision` hash of the row's content: it is not derivable and is not printed.
Python stdlib only."""
import importlib.util, json, os, re, sys, time, uuid

ADAPTERS = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, ADAPTERS)
import tickets  # noqa: E402
import itemdb  # noqa: E402  (tickets.py put the store folder on the path)

OPEN_STATUSES = ("open", "in_progress", "blocked", "on_hold", "deferred")
COLUMNS = ("id", "title", "description", "status", "priority", "issue_type", "assignee", "created_at", "created_by", "updated_at",
           "started_at", "closed_at", "close_reason", "defer_until", "external_ref", "metadata", "labels", "ephemeral", "await_type")
TYPES = json.loads('{"core_types":[{"description":"General work item (default)","name":"task"},{"description":"Bug report or defect","name":"bug"},{"description":"New feature or enhancement","name":"feature"},{"description":"Maintenance or housekeeping","name":"chore"},{"description":"Large body of work spanning multiple issues","name":"epic"},{"description":"Architecture decision record (ADR)","name":"decision"},{"description":"Timeboxed investigation to reduce uncertainty before committing to a story","name":"spike"},{"description":"User story describing a feature from the user\'s perspective","name":"story"},{"description":"Marks completion of a set of related issues (contains no work itself)","name":"milestone"}],"schema_version":1,"system_types":[{"description":"Message between agents or users","name":"message"},{"description":"Molecule root for swarm coordination (bd mol)","name":"molecule"},{"description":"Async coordination gate (bd gate, formula gates)","name":"gate"},{"description":"Audit-trail event (bd set-state)","name":"event"}]}')
STATUSES = json.loads('{"built_in_statuses":[{"category":"active","description":"Available to work (default)","icon":"○","name":"open"},{"category":"wip","description":"Actively being worked on","icon":"◐","name":"in_progress"},{"category":"wip","description":"Blocked by a dependency","icon":"●","name":"blocked"},{"category":"frozen","description":"Deliberately put on ice for later","icon":"❄","name":"deferred"},{"category":"done","description":"Completed","icon":"✓","name":"closed"},{"category":"frozen","description":"Persistent, stays open indefinitely","icon":"📌","name":"pinned"},{"category":"wip","description":"Attached to an agent\'s hook","icon":"◇","name":"hooked"}],"custom_statuses":[{"category":"frozen","name":"on_hold"}],"schema_version":1}')

SCHEMA = json.loads('''{"schema_version":1,"types":{"dependency":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://github.com/steveyegge/beads/internal/types/dependency","properties":{"id":{"type":"string"},"issue_id":{"type":"string"},"depends_on_id":{"type":"string"},"type":{"type":"string","enum":["blocks","parent-child","conditional-blocks","waits-for","related","discovered-from","replies-to","relates-to","duplicates","supersedes","authored-by","assigned-to","approved-by","attests","tracks","until","caused-by","validates","delegated-from"]},"created_at":{"type":"string","format":"date-time"},"created_by":{"type":"string"},"metadata":{"type":"string"},"thread_id":{"type":"string"}},"additionalProperties":false,"type":"object","required":["issue_id","depends_on_id","type","created_at"]},"issue":{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://github.com/steveyegge/beads/internal/types/issue","properties":{"id":{"type":"string"},"title":{"type":"string"},"description":{"type":"string"},"design":{"type":"string"},"acceptance_criteria":{"type":"string"},"notes":{"type":"string"},"spec_id":{"type":"string"},"status":{"type":"string","enum":["open","in_progress","blocked","deferred","closed","pinned","hooked"]},"priority":{"type":"integer"},"issue_type":{"type":"string","enum":["bug","feature","task","epic","chore","decision","message","molecule","gate","spike","story","milestone"]},"is_blocked":{"type":"boolean"},"assignee":{"type":"string"},"owner":{"type":"string"},"estimated_minutes":{"type":"integer"},"created_at":{"type":"string","format":"date-time"},"created_by":{"type":"string"},"updated_at":{"type":"string","format":"date-time"},"started_at":{"type":"string","format":"date-time"},"closed_at":{"type":"string","format":"date-time"},"close_reason":{"type":"string"},"closed_by_session":{"type":"string"},"lease_expires_at":{"type":"string","format":"date-time"},"heartbeat_at":{"type":"string","format":"date-time"},"lease_granted_node":{"type":"string"},"due_at":{"type":"string","format":"date-time"},"defer_until":{"type":"string","format":"date-time"},"external_ref":{"type":"string"},"source_system":{"type":"string"},"metadata":true,"compaction_level":{"type":"integer"},"compacted_at":{"type":"string","format":"date-time"},"compacted_at_commit":{"type":"string"},"original_size":{"type":"integer"},"labels":{"items":{"type":"string"},"type":"array"},"dependencies":{"items":{"properties":{"id":{"type":"string"},"issue_id":{"type":"string"},"depends_on_id":{"type":"string"},"type":{"type":"string","enum":["blocks","parent-child","conditional-blocks","waits-for","related","discovered-from","replies-to","relates-to","duplicates","supersedes","authored-by","assigned-to","approved-by","attests","tracks","until","caused-by","validates","delegated-from"]},"created_at":{"type":"string","format":"date-time"},"created_by":{"type":"string"},"metadata":{"type":"string"},"thread_id":{"type":"string"}},"additionalProperties":false,"type":"object","required":["issue_id","depends_on_id","type","created_at"]},"type":"array"},"comments":{"items":{"properties":{"id":{"type":"string"},"issue_id":{"type":"string"},"author":{"type":"string"},"text":{"type":"string"},"created_at":{"type":"string","format":"date-time"}},"additionalProperties":false,"type":"object","required":["id","issue_id","author","text","created_at"]},"type":"array"},"sender":{"type":"string"},"ephemeral":{"type":"boolean"},"no_history":{"type":"boolean"},"wisp_type":{"type":"string"},"storage_class":{"type":"string"},"pinned":{"type":"boolean"},"is_template":{"type":"boolean"},"bonded_from":{"items":{"properties":{"source_id":{"type":"string"},"bond_type":{"type":"string"},"bond_point":{"type":"string"}},"additionalProperties":false,"type":"object","required":["source_id","bond_type"]},"type":"array"},"await_type":{"type":"string"},"await_id":{"type":"string"},"timeout":{"type":"integer"},"waiters":{"items":{"type":"string"},"type":"array"},"source_formula":{"type":"string"},"source_location":{"type":"string"},"mol_type":{"type":"string"},"work_type":{"type":"string"},"event_kind":{"type":"string"},"actor":{"type":"string"},"target":{"type":"string"},"payload":{"type":"string"}},"additionalProperties":false,"type":"object","required":["id","title","priority","created_at","updated_at"]}}}''')


class NotSupported(Exception):
    """A form this module does not answer."""


def dumps(value):
    """bd's JSON: two-space indent, no ASCII escapes, and Go's HTML escapes."""
    text = json.dumps(value, indent=2, ensure_ascii=False)
    return text.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")


def dumps_compact(value):
    text = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    return text.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")


def json_order(value):
    """A JSON value as Dolt prints it back: every object's keys shorter first, then by bytes (the tables keep them sorted by bytes)."""
    if isinstance(value, dict):
        return {k: json_order(value[k]) for k in sorted(value, key=lambda k: (len(k.encode("utf-8")), k.encode("utf-8")))}
    if isinstance(value, list):
        return [json_order(v) for v in value]
    return value


class Flags:
    """The words of one call: the verb's own positional words, valued flags, and switches."""
    VALUED = {"--limit", "--status", "--parent", "--label", "--type", "--updated-after", "-o", "--since",
              "--issue", "--kind", "--source", "--ref-kind", "--ref", "--at", "--actor", "--payload"}

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
        self.edges_of = self.edges()

    def tickets(self):
        """Every ticket of this home in bd's list order (priority, then newest first), as bd's JSON object. Two tickets of one second keep
        the order of the import that brought them (bd's own, finer than a second); a ticket written here goes newest first."""
        out = []
        first = "(SELECT CASE c.verb WHEN 'import' THEN c.seq ELSE -c.seq END FROM ticket_change c WHERE c.home = t.home AND c.id = t.id ORDER BY c.seq LIMIT 1)"
        for r in self.con.execute("SELECT %s FROM ticket t WHERE home = ? ORDER BY priority, created_at DESC, %s, id DESC" % (", ".join("t." + c for c in COLUMNS), first), (self.home,)):
            t = dict(zip(COLUMNS, r))
            t["labels"], t["metadata"] = json.loads(t["labels"]), json_order(json.loads(t["metadata"]))
            out.append(t)
        return out

    def links(self):
        """Each ticket's edges as (target, type) pairs, in the export's order."""
        out = {}
        for f, to, ty in self.con.execute("SELECT from_id, to_id, type FROM link WHERE home = ? ORDER BY from_id, n, to_id, type", (self.home,)):
            out.setdefault(f, []).append((to, ty))
        return out

    def edges(self):
        """Each ticket's edges as bd prints a dependency: the keys it holds, in bd's order."""
        out = {}
        for f, to, ty, at, by, meta in self.con.execute(
                "SELECT from_id, to_id, type, created_at, created_by, metadata FROM link WHERE home = ? ORDER BY from_id, n, to_id, type", (self.home,)):
            edge = {"issue_id": f, "depends_on_id": to, "type": ty, "created_at": at, "created_by": by, "metadata": meta}
            out.setdefault(f, []).append({k: v for k, v in edge.items() if v is not None})
        return out

    def comments(self, ident):
        return self.con.execute("SELECT id, author, text, created_at FROM comment WHERE home = ? AND ticket_id = ? ORDER BY created_at, id",
                                (self.home, ident)).fetchall()

    def stream(self, ident, source, key="event_type"):
        """The entries of one ticket's stream that carry `key` (a history entry has event_type; an events-journal entry has op)."""
        return [e for e in (json.loads(d) for (d,) in self.con.execute(
            "SELECT data FROM ticket_event WHERE home = ? AND ticket_id = ? AND source = ? ORDER BY n", (self.home, ident, source)))
                if source == "provenance" or key in e]

    def journal(self):
        """Every events-journal entry of the home, oldest first."""
        out = [json.loads(d) for (d,) in self.con.execute("SELECT data FROM ticket_event WHERE home = ? AND source = 'event'", (self.home,))]
        return sorted((e for e in out if "op" in e), key=lambda e: e.get("seq", 0))


def base_row(t):
    """The fields of a ticket every bd row starts with, in bd's order."""
    row = {k: t[k] for k in COLUMNS if t[k] not in (None, "") and k not in ("labels", "metadata", "ephemeral", "await_type")}
    if t["metadata"]:
        row["metadata"] = t["metadata"]
    if t["labels"]:
        row["labels"] = t["labels"]
    return row


def show_dependencies(t, store):
    """A `show` row lists each edge as the ticket it points at, then `dependency_type`. Recorded for a blocks edge; every other type is derived
    the same way (tests/bd-compat-read.test.sh names each derived fixture)."""
    by_id = {x["id"]: x for x in store.tickets()}
    out = []
    for edge in store.edges_of.get(t["id"], []):
        if edge["depends_on_id"] not in by_id:
            raise NotSupported("show: bd's form of a %s edge to a ticket this home does not hold is not recorded" % edge["type"])
        out.append(dict(base_row(by_id[edge["depends_on_id"]]), dependency_type=edge["type"]))
    return out


def export_row(t, store, links, counts, comments, show=False, embed=False):
    """One ticket as bd exports it (embed: with its comments, as `bd export` does). NotSupported when bd would print what the tables do not hold."""
    row = base_row(t)
    if store.edges_of.get(t["id"]):
        row["dependencies"] = show_dependencies(t, store) if show else store.edges_of[t["id"]]
    if comments.get(t["id"]) and show:
        raise NotSupported("show: a comment's place in a show row is not recorded")
    if embed and comments.get(t["id"]):
        row["comments"] = [{"id": i, "issue_id": t["id"], "author": a, "text": x, "created_at": c} for i, a, x, c in store.comments(t["id"])]
    if t["await_type"]:
        row["await_type"] = t["await_type"]
    blocking = sum(1 for _, ty in links.get(t["id"], []) if ty == "blocks")
    dependents = counts.get(t["id"], 0)
    row["dependent_count" if show else "dependency_count"] = dependents if show else blocking
    row["dependency_count" if show else "dependent_count"] = blocking if show else dependents
    row["comment_count"] = len(comments.get(t["id"], []))
    if show and parent_of(links, t["id"]):
        row["parent"] = parent_of(links, t["id"])
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
        row = export_row(t, store, links, counts, comments, embed=verb == "export")
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
    return dumps(rendered(Store(), f, verb)) + "\n", 0      # no row prints [], as bd's --limit 0 answer did: a reader parses it


def show(f):
    if not f.pos:
        raise NotSupported("show")
    store = Store()
    held = {t["id"]: t for t in store.tickets()}
    rows = []
    for ident in f.pos:       # one row per id given, in the order given, as bd prints them in one array
        t = held.get(ident)
        if t is None:
            sys.stderr.write("Error: no issue found matching %r\n" % ident)
            return "", 1
        if "--json" not in f.sw:
            raise NotSupported("show without --json")
        if f.sw - {"--json", "--include-dependents", "--brief-deps"}:
            raise NotSupported("show")
        if f.sw & {"--include-dependents", "--brief-deps"} and (store.edges_of.get(t["id"]) or any(to == t["id"] for es in store.links().values() for to, _ in es)):
            raise NotSupported("show: bd's form of a linked row with --include-dependents or --brief-deps is not recorded")
        rows.append(t)
    links, counts, comments = context(store)
    return dumps([export_row(t, store, links, counts, comments, show=True) for t in rows]) + "\n", 0


def export(f):
    text = "".join(dumps_compact(dict({"_type": "issue"}, **row)) + "\n" for row in rendered(Store(), f, "export"))
    if "-o" in f.val:
        with open(f.val["-o"], "w", encoding="utf-8") as fh:
            fh.write(text)
        return "", 0
    return text, 0


def blocked(f):
    """Each open ticket held by an open blocks edge, as bd prints it: the row's own fields, then the count and the ids of its blockers."""
    store = Store()
    links, _, _ = context(store)
    status = {t["id"]: t["status"] for t in store.tickets()}
    out = []
    for t in store.tickets():
        holders = [to for to, ty in links.get(t["id"], []) if ty == "blocks" and status.get(to, "closed") != "closed"]
        if t["status"] != "closed" and holders:
            out.append(dict(base_row(t), blocked_by_count=len(holders), blocked_by=holders))
    return (dumps(out) if out else "[]") + "\n", 0


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
    store = Store()
    ident = f.pos[0]
    if not any(t["id"] == ident for t in store.tickets()):
        raise NotSupported("comments: bd's answer for a ticket that does not exist is not recorded")
    rows = store.comments(ident)
    if "--json" in f.sw:
        return dumps([{"id": i, "issue_id": ident, "author": a, "text": x, "created_at": c} for i, a, x, c in rows]) + "\n", 0
    if not rows:
        raise NotSupported("comments: bd's text form of a ticket with no comment is not recorded")
    return "\nComments on %s:\n\n%s" % (ident, "".join(comment_block(*r[1:]) for r in rows)), 0


def comment_block(author, text, created_at):
    """One comment as bd's markdown renderer printed the recorded one: a header, then the text indented by four and padded to 80 columns."""
    body = text[:-1] if text.endswith("\n") else text
    if "\n" in body or len(body) > 60 or not body or not re.fullmatch(r"[A-Za-z0-9 .,:;'?!()-]+", body) or body != body.strip():
        raise NotSupported("comments: bd renders this text through a markdown renderer; only one plain line of at most 60 characters is recorded")
    return "[%s] at %s %s\n  \n%s\n\n" % (author, created_at[:10], created_at[11:16], "    " + body.ljust(76))


def stream(verb, f):
    """provenance log --json: the entries ticket_event recorded for the ticket."""
    if "--json" not in f.sw or len(f.pos) < 1:
        raise NotSupported(verb)
    entries = Store().stream(f.pos[-1], "provenance")
    if not entries:
        raise NotSupported(verb + ": no entries recorded for the ticket")
    return dumps(entries) + "\n", 0


def history(f):
    """history <id> --events [--json]: the ticket's history entries, as bd's JSON list or its text."""
    if len(f.pos) != 1 or f.sw - {"--events", "--json"}:
        raise NotSupported("history")
    entries = Store().stream(f.pos[0], "event")
    if not entries:
        raise NotSupported("history: no entries recorded for the ticket")
    if "--json" in f.sw:
        return dumps(entries) + "\n", 0
    if len(entries) == 1:
        raise NotSupported("history: the header of a one-entry history is not recorded")
    out = "\n📜 History events for %s (%d entries)\n\n" % (f.pos[0], len(entries))
    for e in entries:
        out += "%s %s by %s\n" % ((e.get("created_at") or "").replace("T", " ").rstrip("Z"), e.get("event_type"), e.get("actor"))
        for label, key in (("Old", "old_value"), ("New", "new_value"), ("Comment", "comment")):
            if e.get(key):
                out += "  %s: %s\n" % (label, e[key])
        out += "\n"
    return out, 0


def events(f):
    """events tail --since <seq> --limit <n>: the journal lines after seq, one compact JSON object each."""
    if f.pos != ["tail"] or f.sw - {"--json"}:
        raise NotSupported("events")
    since, limit = int(f.val.get("--since", 0)), int(f.val.get("--limit", 0))
    rows = [e for e in Store().journal() if e.get("seq", 0) > since]
    return "".join(dumps_compact(e) + "\n" for e in (rows[:limit] if limit else rows)), 0


def provenance_record(f):
    """provenance record --issue --kind --source [--ref --ref-kind --at --actor --payload]: one more entry on the ticket's provenance stream."""
    need = ("--issue", "--kind", "--source")
    if f.pos != ["record"] or f.sw or not all(k in f.val for k in need) or set(f.val) - set(need + ("--ref", "--ref-kind", "--at", "--actor", "--payload")):
        raise NotSupported("provenance record")
    h = tickets.home()
    st = tickets.open_tickets(h)
    home_id, ident = itemdb.home_id(h), f.val["--issue"]
    st.con.execute("BEGIN IMMEDIATE")
    try:
        c = tickets.copy_of(st.con, home_id, ident)
        if c is None:
            st.con.execute("ROLLBACK")
            sys.stderr.write("Error: no issue found matching %r\n" % ident)
            return "", 1
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        entry = {"id": str(uuid.uuid4()), "issue_id": ident, "kind": f.val["--kind"]}
        for key, flag in (("actor", "--actor"), ("ref", "--ref"), ("ref_kind", "--ref-kind")):
            if flag in f.val:
                entry[key] = f.val[flag]
        entry["source"] = f.val["--source"]
        if "--payload" in f.val:
            entry["payload"] = f.val["--payload"]
        entry["occurred_at"] = f.val.get("--at", now)
        entry["created_at"] = now
        row = {k: c[k] for k in tickets.FIELDS + ("labels", "metadata", "ephemeral", "comments")}
        row.update(id=ident, dependencies=c["edges"], events=[json.loads(x) for x in c["streams"]["events"]],
                   provenance=[json.loads(x) for x in c["streams"]["provenance"]] + [entry])
        tickets.change(st, int(time.time()), home_id, "provenance record", "bd_compat:provenance#%d" % time.time_ns(), row)
        st.con.execute("COMMIT")
    except BaseException:
        if st.con.in_transaction:
            st.con.execute("ROLLBACK")
        raise
    return "✓ Recorded %s provenance %s on %s\n" % (entry["kind"], entry["id"], ident), 0


def memories(f):
    if f.sw != {"--json"} or f.pos:
        raise NotSupported("memories")
    store = Store()
    out = {"schema_version": 1}
    out.update(dict(store.con.execute("SELECT key, value FROM memory WHERE home = ? ORDER BY key", (store.home,)).fetchall()))
    return dumps(out) + "\n", 0


def quick_capture(f):
    """q <title>: bd's quick capture, a task of that title; prints its id alone. The create family makes it."""
    if len(f.pos) != 1 or f.sw or f.val:
        raise NotSupported("q")
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "create.py")
    spec = importlib.util.spec_from_file_location("bd_forms_create", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        return module.run(["create", "--silent", "--title", f.pos[0]], "")
    except Exception as e:  # noqa: BLE001 - the create module's own NotSupported is this module's
        if type(e).__name__ == "NotSupported":
            raise NotSupported("q: " + str(e))
        raise


def swarm_validate(f):
    """swarm validate <epic>: the waves of an epic's open children, by their blocks edges. A cycle or an empty epic is not answered."""
    if len(f.pos) != 2 or f.pos[0] != "validate" or f.sw:
        raise NotSupported("swarm validate")
    store = Store()
    links = store.links()
    rows = {t["id"]: t for t in store.tickets()}
    epic = rows.get(f.pos[1])
    kids = sorted((t for t in rows.values() if parent_of(links, t["id"]) == f.pos[1]), key=lambda t: (t["priority"], t["id"]))
    if epic is None or not kids:
        raise NotSupported("swarm validate: no such epic, or no children")
    left = [t for t in kids if t["status"] != "closed"]
    waves, done = [], {t["id"] for t in kids if t["status"] == "closed"}
    while left:
        front = [t for t in left if all(to in done or to not in rows or to not in {k["id"] for k in kids}
                                        for to, ty in links.get(t["id"], []) if ty == "blocks")]
        if not front:
            raise NotSupported("swarm validate: a cycle")
        waves.append(front)
        done |= {t["id"] for t in front}
        left = [t for t in left if t["id"] not in done]
    out = "\n🐝 Swarm Analysis: %s\n   Epic ID: %s\n   Total issues: %d (%d closed)\n\n📊 Ready Fronts (waves of parallel work):\n" % (
        epic["title"], epic["id"], len(kids), len(kids) - sum(len(w) for w in waves))
    for k, wave in enumerate(waves, 1):
        out += "   Wave %d: %d issues\n" % (k, len(wave)) + "".join("      • %s: %s\n" % (t["id"], t["title"]) for t in wave)
    out += "\n📈 Summary:\n   Estimated worker-sessions: %d\n   Max parallelism: %d\n   Total waves: %d\n\n✓ Swarmable: YES\n\n" % (
        sum(len(w) for w in waves), max(len(w) for w in waves), len(waves))
    return out, 0


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
        return history(f)
    if verb == "events":
        return events(f)
    if verb == "provenance" and f.pos[:1] == ["log"]:
        f.pos = f.pos[1:]
        return stream("provenance", f)
    if verb == "provenance":
        return provenance_record(f)
    if verb == "memories":
        return memories(f)
    if verb == "q":
        return quick_capture(f)
    if verb == "swarm":
        return swarm_validate(f)
    if verb == "schema" and not f.pos and not f.sw:
        return dumps(SCHEMA) + "\n", 0
    if verb == "types" and "--json" in f.sw:
        return dumps_sorted(TYPES), 0
    if verb == "statuses" and "--json" in f.sw:
        return dumps_sorted(STATUSES), 0
    raise NotSupported(verb)


def dumps_sorted(value):
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
