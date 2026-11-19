#!/usr/bin/env python3
"""adapter:tickets - the second copy of the backlog: every field Beads keeps lives in fleet.db too (tickets.sql), written by
bin/jg-backlog.sh in the same call that writes Beads when the main home has config/one-engine. Reads stay on Beads.

  tickets.py import --home <home id> <bd export jsonl>   every row and link of one home's store, keyed (home, id): an id
                                                         another home also holds is a different ticket, never a refusal
  tickets.py write <verb> <args...> --source <id>         after a successful Beads write of that verb: copies the rows the
                                                         call touched from a fresh `bd export` (the ids named in the args,
                                                         the new ids of an add; relink and retag: every row that differs).
                                                         A no-op when the main home has no config/one-engine
  tickets.py ready [--now <iso>]                          one query: the ids `bd ready` gives, for this home
  tickets.py show <id | home:id>                          one copy row as JSON: this home's, or the named home's
  tickets.py compare <bd export jsonl>                    each id whose fields, labels, metadata keys or links differ, one
                                                         line `<id> <field> beads=<v> copy=<v>`; exit 1 when any
A ticket is keyed (home, id). Every read is scoped to the home JG_HOME names; a cross-home read names home:id.
JG_HOME names this home (the store is the main home's state/item-store/fleet.db). Exit 0 ok, 1 refused or a difference,
2 usage. Python stdlib only."""
import json, os, sqlite3, subprocess, sys, time

HERE = os.path.dirname(os.path.realpath(__file__))
STORE = os.path.dirname(HERE)
sys.path.insert(0, STORE)
import itemdb  # noqa: E402

BY = "adapter:tickets"
FIELDS = ("title", "description", "priority", "issue_type", "assignee", "created_at", "closed_at", "close_reason",
          "status", "defer_until", "external_ref")
BULK = {"relink", "retag"}             # verbs that touch rows their args do not name
NEW_ROWS = {"add", "create"}           # verbs that file a row (bd names a minted id): the new ids are touched too


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
    elif st.con.execute("SELECT 1 FROM sqlite_master WHERE name = 'ticket_change_home'").fetchone():
        migrate_to_home_key(st.con, sql.decode("utf-8"))
    return st


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


def migrate_to_home_key(con, sql):
    """A store made when an id was unique across homes (ticket_change_home refused a second home's id) becomes keyed
    (home, id). The ticket and link tables are the fold of ticket_change, so the log is kept as it is - every seq, at and
    source - moved aside, and replayed in seq order into the new tables: the triggers rebuild each row. One transaction;
    the replay must give back every ticket and link row, else nothing changes."""
    con.execute("BEGIN IMMEDIATE")
    try:
        before = [con.execute("SELECT count(*) FROM " + t).fetchone()[0] for t in ("ticket", "link", "ticket_change")]
        for kind, name in con.execute("SELECT type, name FROM sqlite_master WHERE type IN ('view', 'trigger', 'index') "
                                      "AND name IN ('v_ticket_status', 'ticket_change_home', 'ticket_change_final', "
                                      "'ticket_change_kept', 'ticket_apply', 'ticket_drop', 'ticket_status', 'link_to', "
                                      "'ticket_change_once', 'ticket_change_id')").fetchall():
            con.execute("DROP %s %s" % (kind, name))
        con.execute("ALTER TABLE ticket_change RENAME TO ticket_change_old")
        con.execute("DROP TABLE ticket")
        con.execute("DROP TABLE link")
        for stmt in statements(sql):
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
    return dict(scalars, labels=sorted(row.get("labels") or []), metadata=meta, ephemeral=int(bool(row.get("ephemeral"))),
                links=sorted({(row["id"], d["depends_on_id"], d["type"])
                              for d in row.get("dependencies") or []}))


def change(st, at, home_id, verb, source, row):
    n = norm(row)
    body = {k: n[k] for k in FIELDS + ("ephemeral",)}
    body["labels"], body["metadata"] = json.dumps(n["labels"]), json.dumps(n["metadata"], sort_keys=True)
    links = json.dumps([{"to": t, "type": ty} for _, t, ty in n["links"]])
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
    return d


def diffs(beads, copy):
    """(field, beads value, copy value) for each difference between a normalised export row and the copy's row."""
    out = []
    for k in FIELDS + ("ephemeral",):
        if beads[k] != copy[k]:
            out.append((k, beads[k], copy[k]))
    if beads["labels"] != copy["labels"]:
        out.append(("labels", beads["labels"], copy["labels"]))
    for k in sorted(set(beads["metadata"]) | set(copy["metadata"])):
        if beads["metadata"].get(k) != copy["metadata"].get(k):
            out.append(("metadata." + k, beads["metadata"].get(k), copy["metadata"].get(k)))
    if beads["links"] != copy["links"]:
        for lk in sorted(set(beads["links"]) ^ set(copy["links"])):
            side = "beads" if lk in beads["links"] else "copy"
            out.append(("link", ("%s>%s:%s" % lk) if side == "beads" else None, ("%s>%s:%s" % lk) if side == "copy" else None))
    return out


def cmd_import(a):
    rows = rows_of(a.export)
    st = open_tickets(home())
    con = st.con
    at, src = int(time.time()), "import:%s:%d" % (a.home, time.time_ns())
    con.execute("BEGIN IMMEDIATE")
    try:
        for r in rows.values():
            change(st, at, a.home, "import", src, r)
        con.execute("COMMIT")
    except Exception:
        con.execute("ROLLBACK")
        raise
    print("import: %d tickets from %s" % (len(rows), a.home))
    return 0


def beads_export():
    """A fresh `bd export` through the one guarded path (bin/jg-beads.sh)."""
    h = home()
    store = os.environ.get("BEADS_DIR") or open(os.path.join(h, "config", "beads-dir")).read().strip()
    run = subprocess.run([os.path.join(STORE, "..", "..", "bin", "jg-beads.sh"), "export"], capture_output=True, text=True,
                         env=dict(os.environ, BEADS_DIR=store))
    if run.returncode:
        raise Refused("bd export failed: " + (run.stderr or run.stdout).strip().splitlines()[-1][:200])
    rows = {}
    for line in run.stdout.splitlines():
        if line.startswith("{"):
            r = json.loads(line)
            rows[r["id"]] = r
    return rows


def touched(verb, args, beads, known):
    if verb in BULK:
        return set(beads)
    words = {w.split("=", 1)[-1] for w in args}
    ids = {i for i in beads if i in words}
    if verb in NEW_ROWS:
        ids |= {i for i in beads if i not in known}
    return ids


def cmd_write(a):
    h = home()
    if not os.path.exists(os.path.join(itemdb.main_home(h), "config", "one-engine")):
        return 0
    home_id = itemdb.home_id(h)
    beads = beads_export()
    st = open_tickets(h)
    con = st.con
    known = {i for (i,) in con.execute("SELECT id FROM ticket WHERE home = ?", (home_id,))}
    for i in sorted(touched(a.verb, a.args, beads, known)):
        have = copy_of(con, home_id, i)
        if have is not None and not diffs(norm(beads[i]), have):
            continue
        change(st, int(time.time()), home_id, a.verb, "%s#%s" % (a.source, i), beads[i])
    return 0


def cmd_ready(a):
    now = a.now or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    h = home()
    st = open_tickets(h)
    for (i,) in st.con.execute("""
        SELECT t.id FROM ticket t
         WHERE t.home = ? AND (t.status = 'open' OR (t.status = 'deferred' AND t.defer_until IS NOT NULL AND t.defer_until <= ?))
           AND t.ephemeral = 0 AND t.issue_type IS NOT 'gate'
           AND coalesce(json_extract(t.metadata, '$.hold_reason'), '') = '' AND coalesce(t.assignee, '') = ''
           AND NOT EXISTS (SELECT 1 FROM link l JOIN ticket b ON b.home = l.home AND b.id = l.to_id
                            WHERE l.home = t.home AND l.from_id = t.id AND l.type = 'blocks' AND b.status IS NOT 'closed')
         ORDER BY t.priority, t.created_at, t.id""", (itemdb.home_id(h), now)):
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


def cmd_show(a):
    h = home()
    home_id, _, ident = a.ref.rpartition(":") if ":" in a.ref else (itemdb.home_id(h), "", a.ref)
    have = copy_of(open_tickets(h).con, home_id, ident)
    if have is None:
        print("show: %s has no ticket %s" % (home_id, ident))
        return 1
    print(json.dumps(have, sort_keys=True))
    return 0


def main(argv):
    if not argv or argv[0] not in ("import", "write", "ready", "compare", "show"):
        print("usage: tickets.py import|write|ready|compare|show ...", file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "import" and len(rest) == 3 and rest[0] == "--home":
            return cmd_import(type("A", (), dict(home=rest[1], export=rest[2])))
        if cmd == "write" and "--source" in rest and len(rest) >= 3:
            i = rest.index("--source")
            args = rest[:i] + rest[i + 2:]
            return cmd_write(type("A", (), dict(verb=args[0], args=args[1:], source=rest[i + 1])))
        if cmd == "ready":
            return cmd_ready(type("A", (), dict(now=rest[1] if rest[:1] == ["--now"] and len(rest) == 2 else None)))
        if cmd == "show" and len(rest) == 1:
            return cmd_show(type("A", (), dict(ref=rest[0])))
        if cmd == "compare" and len(rest) == 1:
            return cmd_compare(type("A", (), dict(export=rest[0])))
    except Refused as e:
        print(str(e))
        return 1
    except Exception as e:      # a refusal of the store's own rules, or any other fault: one line, never a trace
        print("%s: %s" % (cmd, str(e).splitlines()[0] if str(e) else type(e).__name__))
        return 1
    print("usage: tickets.py import --home <id> <export> | write <verb> <args...> --source <id> | ready [--now <iso>] | compare <export> | show <id|home:id>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
