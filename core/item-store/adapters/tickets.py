#!/usr/bin/env python3
"""adapter:tickets - the backlog: every field of a ticket lives in fleet.db (tickets.sql), written by bd_compat.py's families.

  tickets.py import --home <home id> <bd export jsonl>   every row and link of one home's store, keyed (home, id): an id
                                                         another home also holds is a different ticket, never a refusal.
                                                         Inserts a new row, updates a row whose fields, labels, metadata or
                                                         links changed, leaves an equal row alone; prints the three counts,
                                                         and a second run prints 0 inserted, 0 updated
  tickets.py ready [--now <iso>]                          one query: the ids `bd ready` gives, for this home
  tickets.py show <id | home:id>                          one copy row as JSON: this home's, or the named home's
  tickets.py read <verb> [args] [--shadow]                a backlog read answered from the tables, in exactly the text
                                                         bin/jg-backlog.sh prints from Beads: bin/jg-beads-view.py renders
                                                         the rows rebuilt from the copy, so the two paths share one renderer.
                                                         verb: view|show, list, ready, markdown, questions. list, markdown,
                                                         questions and view are also subcommands of their own name.
                                                         --shadow also asks Beads and, when the two answers differ, opens
                                                         intake:main/tickets-differ-<verb>-<epoch> naming both
  tickets.py spawnable                                    bin/jg-backlog-spawnable.sh's read of the tables: one `<id>\t<project:label>` line per
                                                         startable row and project label (open, not blocked, not a decision card, no assignee or
                                                         hold reason, no open card linked either way)
  tickets.py tree --homes                                 bin/jg-backlog-tree.py over the tables instead of each Beads store
  tickets.py check                                        read-only: whether the tables can be the record. Exit 0 and `tickets: ok (<n> rows)`; exit 2 and
                                                         one line naming the first fault: no tables, tickets.sql differs from tickets.sha256, or
                                                         `<id>: <rule>` (blocked or on hold with no hold_reason; deferred with no reason)
  tickets.py drop-lead-homes                              drops the rows of every home named lead:<id> while the plain <id> home
                                                         holds tickets (a copy imported under the old whoami id), through
                                                         the log's own drop; prints one line per home dropped, run twice
                                                         changes nothing
  tickets.py compare <bd export jsonl>                    each id whose fields, labels, metadata keys or links differ, one
                                                         line `<id> <field> beads=<v> copy=<v>`; exit 1 when any
JG_NOW (an ISO time) replaces the clock for ready's dated holds, in tests. A ticket is keyed (home, id). Every read is scoped to the home JG_HOME names; a cross-home read names home:id.
JG_HOME names this home (the store is the main home's state/item-store/fleet.db). Exit 0 ok, 1 refused or a difference,
2 usage. Python stdlib only."""
import json, os, re, sqlite3, subprocess, sys, time

HERE = os.path.dirname(os.path.realpath(__file__))
STORE = os.path.dirname(HERE)
sys.path.insert(0, STORE)
import itemdb  # noqa: E402
import store as S  # noqa: E402  (begin_write: the one way a writer takes the lock)

BY = "adapter:tickets"
FIELDS = ("title", "description", "priority", "issue_type", "assignee", "created_at", "created_by", "updated_at", "started_at",
          "closed_at", "close_reason", "status", "defer_until", "external_ref", "await_type")
COMMENT_KEYS = ("id", "author", "text", "created_at")
ADDED = ("memory",)                      # tables added to tickets.sql after the first release: an open store gets them (load_missing), a rebuild keeps them
EDGE_KEYS = ("depends_on_id", "type", "created_at", "created_by", "metadata")   # a dependency edge as an export row carries it (issue_id is the row's own id)
STREAMS = ("events", "provenance")       # the export may carry either; Beads' own export carries neither, they come from bd events / bd provenance


class Refused(Exception):
    pass


def home():
    h = os.environ.get("JG_HOME")
    if not h or not os.path.isdir(h):
        raise Refused("JG_HOME must name this home's directory")
    return os.path.realpath(h)


def open_tickets(h):
    """The store, with the ticket tables loaded once when they are missing (tickets.sha256 must match tickets.sql)."""
    import hashlib
    sql = open(os.path.join(STORE, "tickets.sql"), "rb").read()
    want = open(os.path.join(STORE, "tickets.sha256")).read().split()[0]
    if hashlib.sha256(sql).hexdigest() != want:
        raise Refused("tickets.sql differs from tickets.sha256")
    st = itemdb.open_db(h, BY)
    if not st.con.execute("SELECT 1 FROM sqlite_master WHERE name = 'ticket_change'").fetchone():
        st.con.executescript(sql.decode("utf-8"))
    elif (st.con.execute("SELECT 1 FROM sqlite_master WHERE name = 'ticket_change_home'").fetchone()
          or "created_by" not in [c[1] for c in st.con.execute("PRAGMA table_info(ticket)")]
          or not all(t in st.con.execute("SELECT sql FROM sqlite_master WHERE name = 'link'").fetchone()[0] for t in ("'tracks'", "'validates'"))   # an older key, or a link table that refuses a type bd accepts
          or "created_by" not in [c[1] for c in st.con.execute("PRAGMA table_info(link)")]                        # or one that keeps no edge stamp
          or "await_type" not in [c[1] for c in st.con.execute("PRAGMA table_info(ticket)")]):                    # or no gate wait
        rebuild_from_log(st.con, sql.decode("utf-8"))
    else:
        load_missing(st.con, sql.decode("utf-8"))
    return st


def load_missing(con, sql):
    """A table tickets.sql gained after this store loaded it (ADDED: it holds no fold of the log) is created beside the others."""
    have = {r[0] for r in con.execute("SELECT name FROM sqlite_master")}
    for stmt in statements(sql):
        m = re.search(r"^CREATE TABLE (\w+)", stmt, re.M)
        if m and m.group(1) in ADDED and m.group(1) not in have:
            con.execute(stmt)


def statements(script):
    """The complete statements of a script (a trigger body keeps its inner semicolons)."""
    out, cur = [], ""
    for line in script.splitlines(keepends=True):
        cur += line
        if sqlite3.complete_statement(cur):
            if cur.strip():
                out.append(cur)
            cur = ""
    return out


def rebuild_from_log(con, sql):
    """A store made from an older tickets.sql (an id unique across homes, or a ticket with no created_by, comment or ticket_event) becomes
    the current tables. Every table but the log and memory is the fold of ticket_change, so the log is kept as it is - every seq, at and
    source - moved aside, and replayed in seq order into the new tables: the triggers rebuild each row (a field the old log never
    held is NULL until the next import fills it). One transaction; the replay must give back every ticket and link row, else nothing changes."""
    S.begin_write(con)
    try:
        before = [con.execute("SELECT count(*) FROM " + t).fetchone()[0] for t in ("ticket", "link", "ticket_change")]
        mine = set(re.findall(r"^CREATE (?:UNIQUE )?(?:VIEW|TRIGGER|INDEX) (\w+)", sql, re.M)) | {"ticket_change_home"}
        for kind, name in con.execute("SELECT type, name FROM sqlite_master WHERE type IN ('view', 'trigger', 'index')").fetchall():
            if name in mine:
                con.execute("DROP %s %s" % (kind, name))
        con.execute("ALTER TABLE ticket_change RENAME TO ticket_change_old")
        for t in ("ticket", "link", "comment", "ticket_event"):
            con.execute("DROP TABLE IF EXISTS " + t)
        for stmt in statements(sql):
            m = re.search(r"^CREATE TABLE (\w+)", stmt, re.M)
            if not (m and m.group(1) in ADDED and con.execute("SELECT 1 FROM sqlite_master WHERE name = ?", (m.group(1),)).fetchone()):
                con.execute(stmt)
        con.execute("INSERT INTO ticket_change (seq, at, home, id, verb, source, row, links) "
                    "SELECT seq, at, home, id, verb, source, row, links FROM ticket_change_old ORDER BY seq")
        after = [con.execute("SELECT count(*) FROM " + t).fetchone()[0] for t in ("ticket", "link", "ticket_change")]
        if after != before:
            raise Refused("migrate: the replay gave ticket/link/log rows %s, the store held %s" % (after, before))
        con.execute("DROP TABLE ticket_change_old")
        con.execute("COMMIT")
    except Exception:
        con.execute("ROLLBACK")
        raise


def rows_of(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        if line.strip():
            r = json.loads(line)
            out[r["id"]] = r
    return out


def norm(row):
    """One export row as the copy holds it: scalars, a sorted label list, a metadata object, and its links."""
    scalars = {k: (row.get(k) if row.get(k) not in ("", None) else None) for k in FIELDS}
    meta = row.get("metadata") or {}
    comments = sorted(({k: c.get(k) for k in COMMENT_KEYS} for c in row.get("comments") or []), key=lambda c: str(c["id"]))
    streams = {k: [json.dumps(e, sort_keys=True) for e in row[k]] for k in STREAMS if isinstance(row.get(k), list)}
    edges = {}
    for d in row.get("dependencies") or []:       # the export's order, one edge per (target, type)
        edges.setdefault((d["depends_on_id"], d["type"]), {k: d.get(k) for k in EDGE_KEYS})
    return dict(scalars, comments=comments, streams=streams, labels=sorted(row.get("labels") or []), metadata=meta, ephemeral=int(bool(row.get("ephemeral"))),
                links=sorted((row["id"], to, ty) for to, ty in edges), edges=list(edges.values()))


def new_edge(to, ty):
    """A dependency edge a writer adds, stamped as Beads stamps one: now, the actor, and the empty metadata text."""
    return {"depends_on_id": to, "type": ty, "created_at": now_iso(), "created_by": os.environ.get("BEADS_ACTOR") or "juggernaut", "metadata": "{}"}


def change(st, at, home_id, verb, source, row):
    n = norm(row)
    body = {k: n[k] for k in FIELDS + ("ephemeral",)}
    body["labels"], body["metadata"] = json.dumps(n["labels"]), json.dumps(n["metadata"], sort_keys=True)
    body["comments"] = n["comments"]
    for k, v in n["streams"].items():       # a stream the row lacks stays as the copy holds it (see ticket_event)
        body[k] = [json.loads(e) for e in v]
    links = json.dumps([dict({"to": e["depends_on_id"]}, **{k: v for k, v in e.items() if k != "depends_on_id" and v is not None}) for e in n["edges"]])
    st.con.execute("INSERT INTO ticket_change (at, home, id, verb, source, row, links) VALUES (?,?,?,?,?,?,?)",
                   (at, home_id, row["id"], verb, source, json.dumps(body), links))


def copy_of(con, home_id, ident):
    r = con.execute("SELECT * FROM ticket WHERE home = ? AND id = ?", (home_id, ident)).fetchone()
    if r is None:
        return None
    cols = [c[0] for c in con.execute("SELECT * FROM ticket LIMIT 0").description]
    d = dict(zip(cols, r))
    d["labels"], d["metadata"] = sorted(json.loads(d["labels"])), json.loads(d["metadata"])
    d["links"] = sorted(con.execute("SELECT from_id, to_id, type FROM link WHERE home = ? AND from_id = ?", (home_id, ident)).fetchall())
    d["links"] = [tuple(x) for x in d["links"]]
    d["edges"] = [dict(zip(EDGE_KEYS, x)) for x in con.execute(
        "SELECT to_id, type, created_at, created_by, metadata FROM link WHERE home = ? AND from_id = ? ORDER BY n, to_id, type", (home_id, ident))]
    d["comments"] = [dict(zip(COMMENT_KEYS, x)) for x in con.execute(
        "SELECT id, author, text, created_at FROM comment WHERE home = ? AND ticket_id = ? ORDER BY id", (home_id, ident))]
    d["streams"] = {k: [x for (x,) in con.execute("SELECT data FROM ticket_event WHERE home = ? AND ticket_id = ? AND source = ? ORDER BY n",
                                                  (home_id, ident, src))] for k, src in (("events", "event"), ("provenance", "provenance"))}
    d["streams"] = {k: [json.dumps(json.loads(e), sort_keys=True) for e in v] for k, v in d["streams"].items()}
    return d


def diffs(beads, copy):
    """(field, beads value, copy value) for each difference between a normalised export row and the copy's row."""
    out = []
    for k in FIELDS + ("ephemeral",):
        if beads[k] != copy[k]:
            out.append((k, beads[k], copy[k]))
    if beads["labels"] != copy["labels"]:
        out.append(("labels", beads["labels"], copy["labels"]))
    if beads["comments"] != copy["comments"]:
        out.append(("comments", beads["comments"], copy["comments"]))
    for k, v in beads["streams"].items():     # only a stream the export carries is compared
        if v != copy["streams"][k]:
            out.append((k, v, copy["streams"][k]))
    for k in sorted(set(beads["metadata"]) | set(copy["metadata"])):
        if beads["metadata"].get(k) != copy["metadata"].get(k):
            out.append(("metadata." + k, beads["metadata"].get(k), copy["metadata"].get(k)))
    if beads["links"] != copy["links"]:
        for lk in sorted(set(beads["links"]) ^ set(copy["links"])):
            side = "beads" if lk in beads["links"] else "copy"
            out.append(("link", ("%s>%s:%s" % lk) if side == "beads" else None, ("%s>%s:%s" % lk) if side == "copy" else None))
    elif beads["edges"] != copy["edges"]:      # the same links with another stamp, author, metadata or place
        out.append(("link-detail", beads["edges"], copy["edges"]))
    return out


def cmd_import(a):
    rows = rows_of(a.export)
    st = open_tickets(home())
    con = st.con
    at, src = int(time.time()), "import:%s:%d" % (a.home, time.time_ns())
    counts = {"inserted": 0, "updated": 0, "unchanged": 0}
    S.begin_write(con)
    try:
        for r in rows.values():
            have = copy_of(con, a.home, r["id"])
            if have is None:
                counts["inserted"] += 1
            elif diffs(norm(r), have):
                counts["updated"] += 1
            else:
                counts["unchanged"] += 1       # an equal row is never rewritten: no log row
                continue
            change(st, at, a.home, "import", src, r)
        con.execute("COMMIT")
    except Exception:
        con.execute("ROLLBACK")
        raise
    print("import: %d tickets from %s: %d inserted, %d updated, %d unchanged"
          % (len(rows), a.home, counts["inserted"], counts["updated"], counts["unchanged"]))
    return 0


def cmd_drop_lead_homes(a):
    st = open_tickets(home())
    con = st.con
    at, dropped = int(time.time()), []
    S.begin_write(con)
    try:
        for (h,) in con.execute("SELECT DISTINCT home FROM ticket WHERE home LIKE 'lead:%' ORDER BY home").fetchall():
            if not con.execute("SELECT 1 FROM ticket WHERE home = ? LIMIT 1", (h[len("lead:"):],)).fetchone():
                continue
            ids = [i for (i,) in con.execute("SELECT id FROM ticket WHERE home = ? ORDER BY id", (h,)).fetchall()]
            for i in ids:     # row NULL is the log's drop: ticket_drop removes the ticket and its links
                con.execute("INSERT INTO ticket_change (at, home, id, verb, source, row, links) VALUES (?,?,?,?,?,NULL,'[]')",
                            (at, h, i, "drop-lead-home", "drop-lead-homes:%d" % time.time_ns()))
            dropped.append("dropped: %d tickets of %s (plain home %s kept)" % (len(ids), h, h[len("lead:"):]))
        con.execute("COMMIT")
    except Exception:
        con.execute("ROLLBACK")
        raise
    print("\n".join(dropped) if dropped else "drop-lead-homes: nothing to drop")
    return 0


def cmd_ready(a):
    h = home()
    for i in ready_ids(open_tickets(h).con, itemdb.home_id(h), a.now or now_iso()):
        print(i)
    return 0


def cmd_compare(a):
    beads = rows_of(a.export)
    h = home()
    con = open_tickets(h).con
    home_id = itemdb.home_id(h)
    lines = []
    for i in sorted(beads):
        have = copy_of(con, home_id, i)
        if have is None:
            lines.append("%s row beads=present copy=absent" % i)
            continue
        for f, b, c in diffs(norm(beads[i]), have):
            lines.append("%s %s beads=%s copy=%s" % (i, f, json.dumps(b, sort_keys=True), json.dumps(c, sort_keys=True)))
    for (i,) in con.execute("SELECT id FROM ticket WHERE home = ? ORDER BY id", (home_id,)):
        if i not in beads:
            lines.append("%s row beads=absent copy=present" % i)
    print("\n".join(lines))
    return 1 if lines else 0


HOLD_RULES = (
    ("blocked or on hold with no hold_reason", "status IN ('blocked', 'on_hold') AND trim(coalesce(json_extract(metadata, '$.hold_reason'), '')) = ''"),
    ("deferred with no reason", "status = 'deferred' AND defer_until IS NULL AND trim(coalesce(json_extract(metadata, '$.hold_reason'), '')) = ''"),
)


def check_fault(con, home_id):
    """The first fault that keeps the tables from being the record, or None. Reads only: it never loads the tables."""
    import hashlib
    if not con.execute("SELECT 1 FROM sqlite_master WHERE name = 'ticket'").fetchone():
        return "no tables", 0
    sql = open(os.path.join(STORE, "tickets.sql"), "rb").read()
    if hashlib.sha256(sql).hexdigest() != open(os.path.join(STORE, "tickets.sha256")).read().split()[0]:
        return "tickets.sql differs from tickets.sha256", 0
    for rule, where in HOLD_RULES:
        row = con.execute("SELECT id FROM ticket WHERE home = ? AND %s ORDER BY id LIMIT 1" % where, (home_id,)).fetchone()
        if row:
            return "%s: %s" % (row[0], rule), 0
    return None, con.execute("SELECT count(*) FROM ticket WHERE home = ?", (home_id,)).fetchone()[0]


def cmd_check(a):
    h = home()
    fault, n = check_fault(itemdb.open_db(h, BY).con, itemdb.home_id(h))
    print("tickets: %s" % fault if fault else "tickets: ok (%d rows)" % n)
    return 2 if fault else 0


def cmd_show(a):
    h = home()
    home_id, _, ident = a.ref.rpartition(":") if ":" in a.ref else (itemdb.home_id(h), "", a.ref)
    have = copy_of(open_tickets(h).con, home_id, ident)
    if have is None:
        print("show: %s has no ticket %s" % (home_id, ident))
        return 1
    print(json.dumps(have, sort_keys=True))
    return 0


READ_VERBS = ("view", "show", "list", "ready", "markdown", "questions")
VIEW = os.path.join(STORE, "..", "..", "bin", "jg-beads-view.py")
LIB = os.path.join(STORE, "..", "..", "bin", "jg-backlog-lib.sh")
COLS = ("id", "title", "description", "priority", "issue_type", "assignee", "created_at", "created_by", "updated_at", "started_at", "closed_at", "close_reason", "status",
        "defer_until", "external_ref", "labels", "metadata", "ephemeral")


def now_iso():
    return os.environ.get("JG_NOW") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def ready_ids(con, home_id, now, repo=None):
    """The ids `bd ready` gives for one home, in its order (priority, age, id); repo keeps the rows labelled project:<repo>."""
    out = []
    for (i, labels) in con.execute("""
        SELECT t.id, t.labels FROM ticket t
         WHERE t.home = ? AND (t.status = 'open' OR (t.status = 'deferred' AND t.defer_until IS NOT NULL AND t.defer_until <= ?))
           AND t.ephemeral = 0 AND t.issue_type IS NOT 'gate'
           AND coalesce(json_extract(t.metadata, '$.hold_reason'), '') = '' AND coalesce(t.assignee, '') = ''
           AND NOT EXISTS (SELECT 1 FROM link l JOIN ticket b ON b.home = l.home AND b.id = l.to_id
                            WHERE l.home = t.home AND l.from_id = t.id AND l.type = 'blocks' AND b.status IS NOT 'closed')
         ORDER BY t.priority, t.created_at, t.id""", (home_id, now)):
        if repo is None or "project:" + repo in json.loads(labels):
            out.append(i)
    return out


def bd_rows(con, home_id):
    """One home's tickets in bd's JSON shape (what `bd list --json` gives the view): a field the copy holds as NULL is absent,
    each link is a dependency edge, and an ephemeral row is left out as bd leaves it out of a list."""
    edges = {}
    for f, t, ty in con.execute("SELECT from_id, to_id, type FROM link WHERE home = ? ORDER BY from_id, to_id, type", (home_id,)):
        edges.setdefault(f, []).append({"depends_on_id": t, "type": ty})
    rows = []
    for r in con.execute("SELECT %s FROM ticket WHERE home = ? AND ephemeral = 0 ORDER BY created_at, id" % ", ".join(COLS), (home_id,)):
        row = {k: v for k, v in zip(COLS, r) if v is not None and k != "ephemeral"}
        row["labels"], row["metadata"] = json.loads(row["labels"]), json.loads(row["metadata"])
        row["dependencies"] = edges.get(row["id"], [])
        rows.append(row)
    return rows


def render(rows, verb, args, ready=None):
    """The text and exit code bin/jg-beads-view.py gives these rows; ready is bd ready's answer, the ids in its order."""
    env = dict(os.environ)
    tmp = None
    if ready is not None:
        import tempfile
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump([{"id": i} for i in ready], tmp)
        tmp.close()
        env["JG_BEADS_READY"] = tmp.name
    try:
        run = subprocess.run([sys.executable, VIEW, "view" if verb == "show" else verb] + args, input=json.dumps(rows),
                             capture_output=True, text=True, env=env)
    finally:
        if tmp:
            os.unlink(tmp.name)
    return run.stdout, run.returncode


def from_tables(h, verb, args):
    con = open_tickets(h).con
    home_id = itemdb.home_id(h)
    ready, repo = None, None
    if verb == "ready":
        for k, w in enumerate(args):
            repo = w[len("--repo="):] if w.startswith("--repo=") else args[k + 1] if w == "--repo" and k + 1 < len(args) else repo
        ready = ready_ids(con, home_id, now_iso(), repo)
    return render(bd_rows(con, home_id), verb, args, ready)


def from_beads(h, verb, args):
    """The same read through bin/jg-backlog-lib.sh's Beads path, the answer the tables are compared with."""
    run = subprocess.run(["bash", "-c", '. "$1"; shift; jg_backlog_beads_read "$@"', "_", LIB, os.path.join(h, "config"), verb] + args,
                         capture_output=True, text=True)
    return run.stdout, run.returncode


def open_differ(h, verb, mine, beads):
    st = open_tickets(h)
    at = itemdb.stamp(st)
    key = "intake:main/tickets-differ-%s-%d" % (verb, at)
    lines = list(zip(mine[0].splitlines() + [""], beads[0].splitlines() + [""]))
    one = next(((a, b) for a, b in lines if a != b), ("", ""))
    text = "the tickets tables and Beads answer `%s` differently (exit %d vs %d): tables %r, beads %r" % (verb, mine[1], beads[1], one[0][:60], one[1][:60])
    itemdb.or_intake(st, at, key, itemdb.home_id(h), "tickets", st.open, at, key, "intake", itemdb.home_id(h), "tickets", text[:300], st.me)


def cmd_read(a):
    h = home()
    mine = from_tables(h, a.verb, a.args)
    if a.shadow:
        beads = from_beads(h, a.verb, a.args)
        if beads != mine:
            open_differ(h, a.verb, mine, beads)
    sys.stdout.write(mine[0])
    return mine[1]


def cmd_spawnable(a):
    h = home()
    con = open_tickets(h).con
    card = """(%s.issue_type = 'decision' OR coalesce(json_extract(%s.metadata, '$.kind'), '') = 'captain'
              OR instr(%s.title, '[design-ux]') > 0 OR EXISTS (SELECT 1 FROM json_each(%s.labels) WHERE value = 'design-ux'))"""
    c = lambda x: card % (x, x, x, x)
    q = """SELECT t.id, j.value FROM ticket t JOIN json_each(t.labels) j ON j.value LIKE 'project:%%'
     WHERE t.home = ? AND t.status = 'open' AND t.ephemeral = 0 AND t.issue_type IS NOT 'gate' AND NOT %s
       AND (t.defer_until IS NULL OR t.defer_until <= ?)
       AND coalesce(t.assignee, '') = '' AND coalesce(json_extract(t.metadata, '$.hold_reason'), '') = ''
       AND NOT EXISTS (SELECT 1 FROM link l JOIN ticket b ON b.home = l.home AND b.id = l.to_id
                        WHERE l.home = t.home AND l.from_id = t.id AND l.type = 'blocks' AND b.status IS NOT 'closed')
       AND NOT EXISTS (SELECT 1 FROM link l JOIN ticket x ON x.home = l.home AND x.id = l.to_id
                        WHERE l.home = t.home AND l.from_id = t.id AND x.status IS NOT 'closed' AND %s)
       AND NOT EXISTS (SELECT 1 FROM link l JOIN ticket x ON x.home = l.home AND x.id = l.from_id
                        WHERE l.home = t.home AND l.to_id = t.id AND x.status IS NOT 'closed' AND %s)
     ORDER BY t.priority, t.created_at, t.id, j.value""" % (c("t"), c("x"), c("x"))
    for i, label in con.execute(q, (itemdb.home_id(h), now_iso())):
        print("%s\t%s" % (i, label))
    return 0


def cmd_tree(a):
    """bin/jg-backlog-tree.py with its one loader swapped: a home's rows come from the tables, not from its Beads store."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("jg_backlog_tree", os.path.join(STORE, "..", "..", "bin", "jg-backlog-tree.py"))
    tree = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tree)
    h = home()
    con = open_tickets(h).con

    def load(name, _store):
        have = {r[0] for r in con.execute("SELECT DISTINCT home FROM ticket")}
        home_id = name if name in have else name.split(":", 1)[-1]
        rows = [r for r in bd_rows(con, home_id) if r.get("issue_type") != "gate"]
        for r in rows:
            r["parent"] = next((d["depends_on_id"] for d in r["dependencies"] if d["type"] == "parent-child"), None)
        return rows
    tree.load = load
    return tree.main(a.args)


def main(argv):
    if not argv or argv[0] not in ("import", "ready", "compare", "check", "show", "drop-lead-homes", "read", "tree", "spawnable") + READ_VERBS:
        print("usage: tickets.py import|ready|compare|check|show|drop-lead-homes|read|tree ...", file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "import" and len(rest) == 3 and rest[0] == "--home":
            return cmd_import(type("A", (), dict(home=rest[1], export=rest[2])))
        if cmd == "read" and rest and rest[0] in READ_VERBS:
            return cmd_read(type("A", (), dict(verb=rest[0], args=[x for x in rest[1:] if x != "--shadow"], shadow="--shadow" in rest)))
        if cmd in ("view", "list", "markdown", "questions"):
            return cmd_read(type("A", (), dict(verb=cmd, args=[x for x in rest if x != "--shadow"], shadow="--shadow" in rest)))
        if cmd == "spawnable" and not rest:
            return cmd_spawnable(None)
        if cmd == "tree":
            return cmd_tree(type("A", (), dict(args=[x for x in rest if x != "--shadow"])))
        if cmd == "ready" and (not rest or rest[0] == "--now"):
            return cmd_ready(type("A", (), dict(now=rest[1] if rest[:1] == ["--now"] and len(rest) == 2 else None)))
        if cmd == "show" and len(rest) == 1:
            return cmd_show(type("A", (), dict(ref=rest[0])))
        if cmd == "drop-lead-homes" and not rest:
            return cmd_drop_lead_homes(None)
        if cmd == "check" and not rest:
            return cmd_check(None)
        if cmd == "compare" and len(rest) == 1:
            return cmd_compare(type("A", (), dict(export=rest[0])))
    except Refused as e:
        print(str(e))
        return 1
    except Exception as e:      # a refusal of the store's own rules, or any other fault: one line, never a trace
        print("%s: %s" % (cmd, str(e).splitlines()[0] if str(e) else type(e).__name__))
        return 1
    print("usage: tickets.py read <verb> [args] [--shadow] | tree --homes | import --home <id> <export> | ready [--now <iso>] | compare <export> | show <id|home:id>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
