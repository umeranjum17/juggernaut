#!/usr/bin/env python3
"""The one writer for schema.sql. jg-item, the adapters, the proof cases and the simulator call it.

Every call is one transaction with one or more INSERT INTO move rows; the store's triggers refuse an
illegal move and apply a legal one. A call carrying a source the log already holds returns 'again'
and writes nothing (the idempotency key). Pages: an open, hand or climb wakes the new holder unless
that holder was woken for the same key in the last 2 hours; a late mark at the ceiling wakes nobody
(the digest lists it).

The clock: `jg-item` stamps every move with the host clock and registers host_now() on its connection; here each
call's `at` is that host reading (the replay's and the simulator's clock), and host_now() returns it. It also stamps
the move's frame (boot id and host clock minus the boot clock); here `_off` holds that offset, which the simulator
and the proof cases set while the host clock is off, and the tick sets from its own steady reading.
Identity: `jg-item` derives `by` from where it runs and never takes it as an argument. The replay and the simulator
play every program at once, so they pass `by`; a Store made with me=<identity> refuses any other `by`, as the CLI does."""
import copy, hashlib, os, random, re, sqlite3, time

PAGE_QUIET = 7200
PAGE_ROWS, PAGE_BYTES, PAGE_TEXT, PAGE_COUNT_LINE = 200, 32768, 160, 128   # one read: 200 lines, 32 KiB, count line included
LEVELS = {   # the one-word leash; a policy version may override any column. Spend is the owner's at every level.
    "tight":    dict(merge="owner",   land="owner",   release="machine"),   # yolo off (local, local-only, the PR modes): his one word lands it and carries the release
    "standard": dict(merge="owner",   land="machine", release="owner"),     # local-trunk, yolo off: lands on a PASS by itself, goes live on his word
    "loose":    dict(merge="machine", land="machine", release="machine"),   # yolo on: yolo is the release word
}
CLOCK_ALERT = "clock:main/host"
SCHEMA_ALERT = "schema:main/fleet"     # the store's rules differ from the shipped schema (a dropped or changed trigger)
FOLD_ALERT = "fold:main/fleet"         # an item differs from the fold of its moves (a write around the log)
SCHEMA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema.sql")
TICKETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tickets.sql")   # the ticket tables: loaded into the same file, hashed on their own
BUSY_S, WRITE_TRIES = 15, 3              # every home of the host writes one file: each try waits up to 15 s for the write lock, three tries
TICKET_KEEP_S = 7 * 86400                # compact(): a closed or dropped ticket's superseded changes are kept 7 days


class Refused(Exception):
    pass


def begin_write(con, tries=WRITE_TRIES):
    """BEGIN IMMEDIATE: a writer takes the write lock before its first read. A deferred transaction that reads and then writes
    fails at once with "database is locked" when another writer committed in between (a stale WAL snapshot), and no busy wait
    helps it; a lock taken first never goes stale. Each try waits the connection's busy timeout; a lock still held after it
    is tried again after a short random pause, `tries` times in all, then the busy error is raised."""
    for n in range(tries):
        try:
            con.execute("BEGIN IMMEDIATE")
            return
        except sqlite3.OperationalError as e:
            if "locked" not in str(e) or n == tries - 1:
                raise
            time.sleep(random.uniform(0.05, 0.5))


class Store:
    def __init__(self, path=":memory:", schema=SCHEMA, me=None, attach=False):
        self.me, self._now, self._off = me, [0], [0]   # the host clock reading and its offset from the boot clock, shared with every as_() view
        self.boot = "b0"                      # the boot id (the real writer reads /proc/sys/kernel/random/boot_id)
        self.con = sqlite3.connect(path, isolation_level=None, timeout=BUSY_S)
        now = self._now
        self.con.create_function("host_now", 0, lambda: now[0])
        self.con.execute("PRAGMA foreign_keys=ON")
        self.con.execute("PRAGMA recursive_triggers=ON")
        if not attach:                        # a new file returns its free pages to the disk (compact); set before its first table
            self.con.execute("PRAGMA auto_vacuum=INCREMENTAL")
            self.con.executescript(open(schema, encoding="utf-8").read())
        self.kind = {r[0]: r for r in self.con.execute("SELECT kind, first, deadline_s, ceiling, proof, closer FROM kind")}
        self.closers = {r[5] for r in self.kind.values() if r[5].startswith("adapter:")}   # adapters the stamp check always reads
        self.rung = {r[0]: r for r in self.con.execute("SELECT holder, next, rank, deadline_s FROM rung")}
        self.shipped = self.schema_hash()     # the CLI reads this from core/item-store/schema.sha256, shipped with the schema
        self.schema_path = schema             # the re-check re-applies the log to a fresh copy of these rules

    @property
    def _host(self):
        return self._now[0]

    @_host.setter
    def _host(self, at):
        self._now[0] = at

    @staticmethod
    def _digest(rows):
        return hashlib.sha256("\n".join(r[0] or "" for r in rows).encode()).hexdigest()

    def _ticket_objects(self):
        """The names of the objects tickets.sql defines, read from a fresh build of it (the file's own words, never a list kept here)."""
        if not hasattr(self, "_tnames"):
            c = sqlite3.connect(":memory:")
            c.executescript(open(TICKETS, encoding="utf-8").read())
            self._tnames = {r[0]: r[1] for r in c.execute("SELECT name, sql FROM sqlite_master")}
            c.close()
        return self._tnames

    def _objects(self, own):
        """The sql of the live objects, in name order: those tickets.sql defines (own=True) or every other one (own=False)."""
        names = self._ticket_objects() if os.path.exists(TICKETS) else {}
        return [(r[1],) for r in self.con.execute("SELECT name, sql FROM sqlite_master ORDER BY name") if (r[0] in names) == own]

    def schema_hash(self):
        """The hash of every object schema.sql defines. An object neither file defines is in it, so a stray table still changes it."""
        return self._digest(self._objects(False))

    def tickets_ok(self):
        """The ticket tables are either all absent (not loaded yet) or exactly as tickets.sql builds them."""
        have = self._objects(True)
        return not have or self._digest(have) == self._digest([(sql,) for _, sql in sorted(self._ticket_objects().items())])

    def as_(self, me):
        """The same store seen by a writer that runs as `me` (what `jg-item` derives from JG_HOME and JG_TASK_ID); it
        shares the connection and the host clock reading."""
        w = copy.copy(self)
        w.me = me
        return w

    # ------------------------------------------------------------ reads
    def one(self, q, a=()):
        r = self.con.execute(q, a).fetchone()
        return r[0] if r else None

    def item(self, key):
        r = self.con.execute("SELECT kind, holder, holder_id, due_at, home, opened_by, subject FROM item WHERE key=? AND state='open'", (key,)).fetchone()
        return dict(zip(("kind", "holder", "holder_id", "due_at", "home", "opened_by", "subject"), r)) if r else None

    def seen(self, source, key=None):
        """The idempotency key is (outside record, item): one message may open a reply and answer a question, once each."""
        if source is None:
            return False
        if key is None:
            return self.one("SELECT 1 FROM move WHERE source=?", (source,)) is not None
        return self.one("SELECT 1 FROM move WHERE source=? AND key=?", (source, key)) is not None

    def paged_recently(self, key, hid, at):
        return self.one("SELECT 1 FROM move WHERE key=? AND page=? AND at>?", (key, hid, at - PAGE_QUIET)) is not None

    # ------------------------------------------------------------ the write path
    def _write(self, rows):
        """rows: list of dicts for INSERT INTO move. One transaction, under the write lock taken first (begin_write) unless the
        caller's own transaction holds it; refused as a whole."""
        if self.me is not None and any(r.get("by") != self.me for r in rows):
            raise Refused("by: the writer stamps who it is (%s); it never takes a by" % self.me)
        cols = ("at", "verb", "key", "kind", "home", "subject", "project", "parent", "by", "source", "holder", "holder_id", "due_at", "ends", "why", "options", "page", "frame")
        frame = "%s:%d" % (self.boot, self._off[0])
        rows = [dict(r, frame=r.get("frame", frame)) for r in rows]
        own = not self.con.in_transaction
        try:
            if own:
                begin_write(self.con)
        except sqlite3.Error as e:
            raise Refused(" ".join(str(e).split()))
        try:
            self.con.execute("SAVEPOINT w")
            for r in rows:
                self.con.execute("INSERT INTO move(%s) VALUES(%s)" % (",".join(cols), ",".join("?" * len(cols))), tuple(r.get(c) for c in cols))
            self.con.execute("RELEASE w")
        except sqlite3.Error as e:
            self.con.execute("ROLLBACK TO w")
            self.con.execute("RELEASE w")
            if own:
                self.con.execute("ROLLBACK")
            raise Refused(" ".join(str(e).split()))
        if own:
            self.con.execute("COMMIT")

    def first_holder(self, kind, home, named=None):
        k = self.kind[kind]
        h = named if k[1] == "named" else k[1]
        return "main" if h == "lead" and home == "main" else h

    def holder_id(self, holder, home, lane=None):
        return {"worker": lane or home, "lead": "lead:" + home if home != "main" else "main", "main": "main",
                "owner": "owner", "outside": "outside", "tick": "tick"}[holder]

    def limit(self, kind, holder):
        k = self.kind[kind]
        return min(k[2], self.rung[holder][3]) if k[1] == "named" else k[2]

    def set_policy(self, at, project, level, by, source, mode="local", lanes=4, trunk="main", **over):
        """Write the next policy version: the level's leash, then his per-decision overrides. In the fleet this is the
        policy adapter (the cut-over import, or his answer to a policy question) calling store.py in-process; `jg-item`
        has no policy command, because its writer runs as a worker, a lead or Main."""
        self._host = at
        if self.me is not None and by != self.me:
            raise Refused("by: the writer stamps who it is (%s); it never takes a by" % self.me)
        v = (self.one("SELECT max(version) FROM policy WHERE project=?", (project,)) or 0) + 1
        row = dict(LEVELS[level], **{k: x for k, x in over.items() if k in ("merge", "land", "release")})
        rung = {k: over.get(k) for k in ("worker_s", "lead_s", "main_s", "owner_s")}
        try:
            self.con.execute("INSERT INTO policy VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                             (project, v, level, mode, row["merge"], row["land"], row["release"], lanes, trunk,
                              rung["worker_s"], rung["lead_s"], rung["main_s"], rung["owner_s"], at, by, source))
        except sqlite3.Error as e:
            raise Refused(" ".join(str(e).split()))
        return v

    def base(self, project):
        """The ref a review compares against, from the project's policy only: a local project reviews against its own
        trunk branch; a PR project against the remote's copy of it. No policy row means no base: the review refuses."""
        r = self.con.execute("SELECT mode, trunk FROM v_policy WHERE project=?", (project,)).fetchone()
        if not r:
            raise Refused("base: %s has no policy row, so a review has no base (there is no default)" % project)
        mode, trunk = r
        return ("refs/heads/" if mode in ("local", "local-only", "local-trunk") else "refs/remotes/origin/") + trunk

    def release_push(self, at, project, pr, head, source=None):
        """The trunk adapter pushed `head` into the project's release pull request `pr` (main's `jg-trunk.sh release`: it
        opens the one release pull request from the trunk's green pin, or pushes into the open one). The release step and
        its question are keyed by that pull request, as a merge is: the first push opens the step where the leash
        lets the machine release, else asks him once; a later push into the same pull request is a note on whichever is
        open. So a project has at most one open release question, a landing never asks again, and his yes lets that one
        pull request out (hard rule 2 counts merges per pull request). His adapter opens the step in the write of his
        yes (close(..., then=[the step])), as for a land or a merge.
        It writes as the tick whatever the caller's stamp: the store, not the caller, decides between his question and
        the step, and only Main or the tick may open a step question. So the trunk adapter, stamped adapter:trunk,
        calls this and release_out alike; the push itself is the caller's fact, kept in the source push:<head>."""
        w = self.as_("tick") if self.me not in (None, "tick") else self
        if source is None:                    # a push is keyed by its head: no source, no idempotency
            raise Refused("release_push: a push needs its source (push:<head>)")
        step = "release:%s@%s" % (project, pr)
        subject = "%s@%s" % (project, pr)
        if self.seen(source, step) or self.seen(source, "question:" + step):    # the same push again: nothing new
            return "again"
        machine = self.one("SELECT release FROM v_policy WHERE project=?", (project,)) == "machine"
        if self.item("question:" + step):
            return w.note(at, "question:" + step, "tick", "pushed %s into release pull request %s" % (head, pr), source=source)
        if self.item(step):
            if machine:
                return w.note(at, step, "tick", "pushed %s into release pull request %s" % (head, pr), source=source)
            # his yes covered the head his question showed; a push after it asks once more (main's rule: a word covers its
            # own commit and every commit under it, never one above it). The open step stays; his next yes is a note on it.
            w.note(at, step, "tick", "pushed %s into release pull request %s after his yes: asked again" % (head, pr), source=source)
            return w.open(at, "question:" + step, "question", project, subject,
                             "release word again: release pull request %s of %s moved to %s after your yes; let it go out?" % (pr, project, head),
                             "tick", source=source)
        yes = self.one("SELECT 1 FROM item WHERE key=? AND kind='question' AND state='done' AND closed_by LIKE 'owner:%' AND outcome LIKE '% pick=yes'",
                       ("question:" + step,))
        if yes or machine:   # his yes already covers this pull request
            return w.open(at, step, "release", project, subject, "release pull request %s of %s, at %s" % (pr, project, head), "tick",
                             source=source, project=project)
        return w.open(at, "question:" + step, "question", project, subject,
                         "release word: let release pull request %s of %s go out (at %s)?" % (pr, project, head), "tick", source=source)

    def covered_head(self, project, pr):
        """The head his newest yes on release pull request `pr` covers: the last push recorded before that yes (each push's
        source is `push:<head>`). None when he has not said yes, or on a machine-release project (nothing to cover)."""
        step = "release:%s@%s" % (project, pr)
        yes_at = self.one("SELECT max(closed_at) FROM item WHERE key=? AND kind='question' AND state='done' AND closed_by LIKE 'owner:%%' "
                          "AND outcome LIKE '%% pick=yes'", ("question:" + step,))
        if yes_at is None:
            return None
        src = self.one("SELECT source FROM move WHERE key IN (?, ?) AND source LIKE 'push:%%' AND at <= ? "
                       "ORDER BY seq DESC LIMIT 1", (step, "question:" + step, yes_at))
        return src[len("push:"):] if src else None

    def release_out(self, at, project, pr, head, source=None):
        """The trunk adapter's record that release pull request `pr` merged at `head`: the step closes done (its blockers
        close in the same write, Y10). The stamp check reads this adapter's own record."""
        return self.close(at, "release:%s@%s" % (project, pr), "done", "released:%s at %s" % (pr, head), "adapter:trunk", source=source)

    def landed(self, subject):
        """What landed for a ticket, read from its closed land (or merge) item: the commit the trunk lander put on the
        trunk (`trunk:<commit>`), or the merged PR. A cleanup's landed check reads this record and never looks for the
        lane copy's own head on a branch, so a lander that re-cuts the commit (same patch, new hash) still reads landed.
        It reads a close only once the stamp check has passed it with no finding: a raw write of the record is
        found within one tick and never lets a cleanup discard unlanded work (hard rule 3)."""
        r = self.con.execute("SELECT i.outcome, m.seq FROM item i JOIN move m ON m.key = i.key AND m.verb = 'close' AND m.at = i.closed_at"
                             " WHERE i.subject=? AND i.kind IN ('land','merge') AND i.state='done' ORDER BY i.id DESC LIMIT 1", (subject,)).fetchone()
        if not r or r[1] > (self.one("SELECT seq FROM cursor WHERE reader='stamp-check'") or 0) or self.seen("forged:move:%d" % r[1]):
            return None
        return r[0].split(":", 1)[1].split()[0]

    def pages(self, reader, rows=PAGE_ROWS, size=PAGE_BYTES):
        """What `jg item pages` prints for a reader (main, lead:<home>): only pages past its cursor, one line per item
        with the item's state now (never the history behind it), at most `rows` lines and `size` bytes, then one count
        line. Pages of items closed since they were paged are counted, not listed. Reading moves nothing: `ack` moves
        the cursor to the `ack=` seq of the count line, so a reader that dies before acting reads the same lines again,
        and lines past the cap come on the next read. Returns (lines, ack_seq)."""
        cur = self.one("SELECT seq FROM cursor WHERE reader=?", (reader,)) or 0
        ps = self.con.execute("SELECT max(seq), key FROM move WHERE page=? AND seq>? GROUP BY key ORDER BY max(seq)", (reader, cur)).fetchall()
        out, used, last, closed, i = [], 0, cur, 0, 0
        for i, (seq, key) in enumerate(ps):
            it = self.con.execute("SELECT kind, state, holder_id, due_at, late_at, owes FROM item WHERE key=? ORDER BY gen DESC LIMIT 1", (key,)).fetchone()
            if it is None or it[1] != "open":
                closed, last = closed + 1, seq
                continue
            line = "%d\t%s\t%s\t%s\tdue=%d%s\t%s" % (seq, key, it[0], it[2], it[3], "\tlate" if it[4] else "", " ".join(it[5].split())[:PAGE_TEXT])
            if len(out) >= rows or used + len(line) + 1 > size - PAGE_COUNT_LINE:
                break
            out.append(line)
            used, last = used + len(line) + 1, seq
        else:
            i = len(ps)
        more = len(ps) - i
        out.append("pages: %d listed, %d closed since paged, %d more after ack; ack=%d" % (len(out), closed, more, last))
        return out, last

    def tick_lease(self, steady, boot=None, min_age=240):
        """One tick per host. Every home's watcher runs the tick (every 300 s on the host); the one that finds the lease
        older than min_age seconds, or absent, takes it and runs, and the others return at once. The lease is the cursor
        row tick-lease:<boot id>, its seq the boot clock's seconds (CLOCK_BOOTTIME: one clock for every process of the
        host, never set back), taken in one statement under the store's write lock, so two homes ticking in the same
        second cannot both win. When Main's watcher stops, a Squad Lead home's tick takes over within one cycle."""
        cur = self.con.execute(
            "INSERT INTO cursor(reader, seq) VALUES(?, ?) ON CONFLICT(reader) DO UPDATE SET seq = excluded.seq"
            " WHERE excluded.seq - cursor.seq >= ?", ("tick-lease:%s" % (boot or self.boot), int(steady), int(min_age)))
        return cur.rowcount == 1

    def ack(self, reader, seq):
        """Move a reader's cursor to the ack seq its last read printed: never past what a read shows now (only what was
        shown is acknowledged), and never back (the schema refuses it, R31)."""
        shown = self.pages(reader)[1]
        if seq > shown:
            raise Refused("ack: %d is past what a read shows (ack=%d): read first, then acknowledge" % (seq, shown))
        self.con.execute("INSERT INTO cursor VALUES(?, ?) ON CONFLICT(reader) DO UPDATE SET seq=excluded.seq", (reader, seq))

    def ready(self, at, recon_key, draft, by, source=None):
        """A Recon's draft is ready (Y8). In the same write: a note on the Recon's work item, and the next critic round as
        a steer to its critic lane, found by the link set at the critic's spawn (the critic's work item names the Recon's
        work item as its parent), never by a name. With no critic lane yet, the same write opens a dispatch item for one.
        Either climbs on its own deadline if nobody acts."""
        self._host = at
        if self.seen(source, recon_key):
            return "again"
        r = self.con.execute("SELECT home, subject FROM item WHERE key=? AND state='open' AND kind='work'", (recon_key,)).fetchone()
        if not r:
            raise Refused("ready: %s is not an open Recon work item" % recon_key)
        home, subj = r
        crit = self.con.execute("SELECT key, holder_id, subject FROM item WHERE kind='work' AND state='open' AND parent=?", (recon_key,)).fetchone()
        rows = [dict(at=at, verb="note", key=recon_key, by=by, source=source, why="draft ready: " + draft)]
        if crit:
            rows.append(dict(at=at, verb="open", key="steer:%s/round@%s" % (crit[0].split(":", 1)[1], draft), kind="steer", home=home, subject=crit[2],
                             parent=recon_key, by=by, holder="worker", holder_id=crit[1], due_at=at + 1800, page=crit[1],
                             why="critic round on draft %s of %s" % (draft, subj)))
        else:
            hid = self.holder_id(self.first_holder("dispatch", home), home)
            rows.append(dict(at=at, verb="open", key="dispatch:%s/%s/critic" % (home, subj), kind="dispatch", home=home, subject=subj,
                             parent=recon_key, by=by, holder=self.first_holder("dispatch", home), holder_id=hid, due_at=at + 1800, page=hid,
                             why="start the critic of %s: draft %s is ready" % (subj, draft)))
        self._write(rows)
        return "round" if crit else "dispatch"

    def rung_limit(self, holder, project):
        col = {"worker": "worker_s", "lead": "lead_s", "main": "main_s", "owner": "owner_s"}.get(holder)
        p = self.one("SELECT %s FROM v_policy WHERE project=?" % col, (project,)) if col and project else None
        return p or self.rung[holder][3]

    def open(self, at, key, kind, home, subject, owes, by, source=None, named=None, lane=None, due=None, parent=None, extra=(), quiet=False, project=None,
             options=None):
        """Open an item; if the cause is already open, the same arrival becomes a note on it. A question offers picks
        (`options`, 'a|b'; a step question for a landing, merge or release offers 'yes|no')."""
        self._host = at
        if self.seen(source, key):
            return "again"
        if kind == "question" and options is None:
            options = "yes|no"
        if kind == "blocker" and parent and not self.item(parent) and \
                self.one("SELECT state FROM item WHERE key=? ORDER BY gen DESC LIMIT 1", (parent,)) == "done":
            return "clear"          # its step is already done: nothing is held back, so nothing is written (Y10)
        if self.item(key):
            self._write([dict(at=at, verb="note", key=key, by=by, source=source, why=owes)])
            return "note"
        h = self.first_holder(kind, home, named)
        hid = self.holder_id(h, home, lane)
        d = at + (min(due, self.limit(kind, h)) if due else self.limit(kind, h))
        page = None if quiet or self.paged_recently(key, hid, at) or h in ("outside", "tick") else hid
        if project is None and kind in ("work", "land", "merge", "release"):
            project = home
        self._write([dict(at=at, verb="open", key=key, kind=kind, home=home, subject=subject, project=project, parent=parent, by=by, source=source,
                          holder=h, holder_id=hid, due_at=d, why=owes, options=options, page=page)] + list(extra))
        return "open"

    @staticmethod
    def alert_key(cause, home, subject):
        """An alert's key: one open alert per subject and cause (the store refuses any other shape)."""
        return "%s:%s/%s" % (re.sub(r"[:/]+", "-", cause), home, subject)

    def note(self, at, key, by, text, source=None):
        self._host = at
        if self.seen(source, key):
            return "again"
        self._write([dict(at=at, verb="note", key=key, by=by, source=source, why=text)])
        return "note"

    def hand(self, at, key, holder, hid, due_in, why, by, source=None):
        self._host = at
        if self.seen(source, key):
            return "again"
        page = None if self.paged_recently(key, hid, at) or holder in ("outside", "tick") else hid
        self._write([dict(at=at, verb="hand", key=key, by=by, source=source, holder=holder, holder_id=hid, due_at=at + due_in, why=why, page=page)])
        return "hand"

    def close(self, at, key, ends, why, by, source=None, then=()):
        """Close done (why = the proof) or dropped (why = the reason); `then` opens successors in the same transaction."""
        self._host = at
        if self.seen(source, key):
            return "again"
        if ends == "done" and key.startswith("release:") and self.item("question:" + key):
            # his release word was asked again (a push after his yes) and is not answered: the release waits for it
            raise Refused("release: his release question %s is open: no release past the head his yes covered" % ("question:" + key))
        rows = [dict(at=at, verb="close", key=key, by=by, source=source, ends=ends, why=why)]   # a lane's alerts and steers close in the store
        for s in then:
            if self.item(s["key"]):      # the successor is already open: the same cause, so a note on it
                rows.append(dict(at=at, verb="note", key=s["key"], by=by, why="again: " + s["owes"]))
                continue
            h = self.first_holder(s["kind"], s["home"], s.get("named"))
            hid = self.holder_id(h, s["home"], s.get("lane"))
            pj = s.get("project") or (s["home"] if s["kind"] in ("work", "land", "merge", "release") else None)
            hid = s.get("holder_id", hid)
            rows.append(dict(at=at, verb="open", key=s["key"], kind=s["kind"], home=s["home"], subject=s["subject"], project=pj, parent=s.get("parent", key), by=by,
                             holder=h, holder_id=hid, due_at=at + min(s.get("due") or 10 ** 9, self.limit(s["kind"], h)), why=s["owes"],
                             options=s.get("options") or ("yes|no" if s["kind"] == "question" else None),
                             page=None if h in ("outside", "tick") else hid))
        self._write(rows)
        return ends

    def tick(self, at, steady=None):
        """Climb every open item past its deadline one rung, or mark it late at its ceiling. Source = key@due, so a
        second run of the same tick writes nothing.

        The clock leap: every deadline move carries its writer's frame, read with its stamp: the boot id and the
        host clock minus a clock the host's clock setting cannot move (the real `jg-item` and tick read CLOCK_BOOTTIME;
        the probe passes the true time as `steady`). The tick moves an open deadline whose last deadline move's frame is
        more than 300 s off its own by exactly that difference (a tick hand to the same holder), so it keeps its true
        time in either direction, however late the tick runs and whenever the move was written. A move from another boot
        is not moved (a reboot starts afresh). The clock alert opens on Main when the tick's own offset moved by more
        than 300 s since its last run, or when it moves a deadline, and closes at the run where the offset is back within
        300 s of where it was before the first leap. The tick keeps one line beside fleet.db: boot id, offset at its last
        run, offset before the first open leap."""
        self._host = at
        out = []
        off = None if steady is None else at - steady
        if off is not None:
            self._off[0] = off
        last = getattr(self, "_clock", None)   # (offset at the last run, offset before the first open leap)
        base = last[1] if last else None
        if off is not None:
            boot = self.boot + ":"
            moves, leaps = [], []
            for key, h, hid, due, frame in self.con.execute(
                    "SELECT i.key, i.holder, i.holder_id, i.due_at, m.frame FROM item i JOIN move m ON m.seq = (SELECT max(seq) FROM move x"
                    " WHERE x.key = i.key AND x.verb IN ('open','hand','climb')) WHERE i.state='open' AND i.late_at IS NULL AND i.key<>?"
                    " AND m.frame LIKE ?", (CLOCK_ALERT, boot + "%")).fetchall():
                leap = off - int(frame[len(boot):])
                if abs(leap) > 300:                   # set in another frame: keep its true remaining time; one the leap makes
                    leaps.append(leap)
                    moves.append(dict(at=at, verb="hand", key=key, by="tick", source="clock-leap:%s@%d" % (key, at), holder=h, holder_id=hid,
                                      due_at=min(max(due + leap, at + 1), at + 1209600),   # due is due at the next tick
                                      why="clock: the host clock leapt %+d s since this deadline was set; the deadline moved with it" % leap))
            own = off - last[0] if last is not None else 0
            if moves or abs(own) > 300:
                lp = own if abs(own) > 300 else leaps[0]
                if not self.item(CLOCK_ALERT):
                    base = last[0] if last is not None else off - lp
                    head = dict(at=at, verb="open", key=CLOCK_ALERT, kind="alert", home="main", subject="host", by="tick", source="clock@%d" % at,
                                holder="main", holder_id="main", due_at=at + 900, page="main",
                                why="the host clock leapt %+d s: every open deadline moved with it" % lp)
                else:
                    head = dict(at=at, verb="note", key=CLOCK_ALERT, by="tick", source="clock@%d" % at, why="the host clock leapt %+d s again" % lp)
                self._write([head] + moves)
        if off is not None and base is not None and abs(off - base) <= 300 and self.item(CLOCK_ALERT):
            self._write([dict(at=at, verb="close", key=CLOCK_ALERT, by="tick", ends="done", source="clock-ok@%d" % at,
                              why="gone: the host clock is back within 300 s of where it was before the leap")])
        if off is not None:
            self._clock = (off, base if self.item(CLOCK_ALERT) else None)
        last = getattr(self, "_last_fold", None)       # None until the first re-check, so the first tick runs it
        self.audit(at, fold=last is None or at // 900 != last // 900)   # the re-check: at the first tick, then every 15 minutes
        due = self.con.execute("SELECT key, kind, holder, holder_id, due_at, home, project FROM item WHERE state='open' AND due_at<=? AND late_at IS NULL", (at,)).fetchall()
        for key, kind, h, hid, d, home, project in due:
            src = "tick:%s@%d" % (key, d)
            if self.seen(src):
                continue
            ceil = self.kind[kind][3]
            if self.rung[h][2] < self.rung[ceil][2]:
                nh = self.rung[h][1]
                if home == "main" and nh == "lead":
                    nh = "main"
                nid = self.holder_id(nh, home)
                page = None if self.paged_recently(key, nid, at) else nid
                why = "climb: %s past its deadline" % h
            else:
                nh, nid, page, why = h, hid, None, "late at its ceiling: listed in the digest"
            try:
                self._write([dict(at=at, verb="climb", key=key, by="tick", source=src, holder=nh, holder_id=nid,
                                  due_at=at + self.rung_limit(nh, project), why=why, page=page)])
                out.append((key, h, nh))
            except Refused:
                pass
        return out

    def compact(self, at, keep_s=TICKET_KEEP_S):
        """Keep the file small; the tick runs it once per host tick. First it erases each change of the ticket log older than
        keep_s whose ticket is closed or dropped: the log's own trigger (tickets.sql, ticket_change_kept) skips every change
        the ticket tables are folded from, so no ticket, link, comment or event changes, and an active ticket keeps its whole
        history. While the live ticket objects differ from tickets.sql the log is left alone. Then a file made before
        incremental auto-vacuum is rebuilt with it once (VACUUM); after that each run returns the free pages to the disk.
        Items and moves are never touched. Returns (changes erased, pages returned)."""
        erased = 0
        if self._objects(True) and self.tickets_ok():
            begin_write(self.con)
            try:
                erased = self.con.execute(
                    "DELETE FROM ticket_change WHERE at < ? AND NOT EXISTS (SELECT 1 FROM ticket t WHERE t.home = ticket_change.home"
                    " AND t.id = ticket_change.id AND t.status IS NOT 'closed')", (at - keep_s,)).rowcount
                self.con.execute("COMMIT")
            except sqlite3.Error:
                self.con.execute("ROLLBACK")
                raise
        pages = self.one("PRAGMA page_count")
        if self.one("PRAGMA auto_vacuum") != 2:
            self.con.execute("PRAGMA auto_vacuum=INCREMENTAL")
            self.con.execute("VACUUM")
            self.con.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall()      # once: the rebuild passed the whole file through the WAL
        else:
            self.con.execute("PRAGMA incremental_vacuum").fetchall()          # stepped to the end: each step returns one page
        return erased, pages - self.one("PRAGMA page_count")

    def audit(self, at, fold=False):
        """Every tick: the schema hash against the shipped one. Every 15 minutes: the re-check (the log re-applied to the
        shipped rules; it finds a write around the log, as the fold check did, and a write a dropped check let through). Each
        mismatch opens one alert on Main (a repeat is a note), so a dropped trigger or a write around the log is seen."""
        found = []
        if self.schema_hash() != self.shipped or not self.tickets_ok():
            found.append((SCHEMA_ALERT, "the store's rules differ from the shipped schema"))
        if fold:
            self._last_fold = at
            from recheck import recheck     # re-apply the whole log to a fresh copy of the shipped rules
            bad = [(t, k) for t, k, _ in recheck(self.con, self.schema_path)]
            if bad:
                found.append((FOLD_ALERT, "%d moves or items fail the re-check under the shipped rules, first %s" % (len(bad), bad[0])))
        for key, why in found:
            if not self.item(key):
                try:
                    self._write([dict(at=at, verb="open", key=key, kind="alert", home="main", subject="fleet", by="tick", source="%s@%d" % (key, at),
                                      holder="main", holder_id="main", due_at=at + 900, page="main", why=why)])
                except Refused:
                    pass
        return found

    # ------------------------------------------------------------ the count rule and the fold check
    def fold_check(self):
        """Rebuild every item from the move log and compare with the item table. Returns the keys that differ."""
        rebuilt, gen = {}, {}
        for verb, key, kind, home, subject, holder, hid, due, ends, why, at, by in self.con.execute(
                "SELECT verb, key, kind, home, subject, holder, holder_id, due_at, ends, why, at, by FROM move ORDER BY seq"):
            if verb == "open":
                gen[key] = gen.get(key, 0) + 1
                rebuilt[(key, gen[key])] = ["open", holder, hid, due, None]
            elif verb in ("hand", "climb"):
                r = rebuilt[(key, gen[key])]
                r[1], r[2], r[3] = holder, hid, due
            elif verb == "close":
                rebuilt[(key, gen[key])][0] = ends
                rebuilt[(key, gen[key])][4] = why
        bad = []
        have = {(k, g): [s, h, hid, d, o] for k, g, s, h, hid, d, o in self.con.execute(
            "SELECT key, gen, state, holder, holder_id, due_at, outcome FROM item")}
        for k in set(rebuilt) | set(have):
            if rebuilt.get(k) != have.get(k):
                bad.append(k)
        return bad

    def count_check(self):
        """the board's count (v_count): came in = open + done + dropped per kind. It differs only when a trigger is
        bypassed, which fold_check already finds; kept for the board, not as a separate check."""
        rows = self.con.execute("SELECT kind, came_in, open, done, dropped, closed_without_reason FROM v_count").fetchall()
        return [r for r in rows if r[1] != r[2] + r[3] + r[4] or r[5]]

    def _cascade_cause(self, key, at, why):
        """The close that caused a cascade close at the same stamp: a blocker's step, or a lane's work (its alerts and steers)."""
        m = re.match(r"gone: its step (\S+) closed done", why)
        if m:
            return m.group(1)
        if why.startswith("subject gone: its lane closed"):
            r = self.con.execute("SELECT subject, home FROM item WHERE key=? ORDER BY (closed_at = ?) DESC, gen DESC LIMIT 1", (key, at)).fetchone()
            return r and self.one("SELECT key FROM item WHERE kind='work' AND subject=? AND home=? AND closed_at=? ORDER BY gen DESC LIMIT 1", (r[0], r[1], at))
        return None

    def stamp_check(self, at, logs):
        """The tick's stamp check, every minute, over the moves since its own cursor. `logs` maps a channel (owner:chat,
        owner:board, owner:registry, adapter:chat, adapter:trunk, ...) to the set of (record id, item key) pairs its own
        log holds; owner:registry's log is the cut-over run's own output, written once: a
        board answer names its card and the card names the item; a chat answer carries the bridge's reply reference; a
        policy version's item is 'policy:<project>'. A move stamped by a channel with a log must carry a pair found there
        (a next step opened in the same write as his message carries its parent's pair). A drop 'subject gone' must find
        its subject's work closed at that time; a drop 'ended' must be past its deadline; a tick hand must come with a clock
        leap (the alert's open or note at the same stamp). Each mismatch opens one
        security item on Main. Returns the mismatches as (what, ref, pair)."""
        self._host = at
        cur = self.one("SELECT seq FROM cursor WHERE reader='stamp-check'") or 0
        top = self.one("SELECT max(seq) FROM move") or 0
        bad = []
        for seq, mat, verb, key, by, src, parent, ends, why, subj in self.con.execute(
                "SELECT seq, at, verb, key, by, source, parent, ends, why, subject FROM move WHERE seq > ? ORDER BY seq", (cur,)).fetchall():
            # every owner channel and every adapter that alone closes a kind is checked (no log: nothing it stamped is
            # true); any other adapter once its log is wired
            if by.startswith("owner:") or by in self.closers or by in logs:
                pair = (src, key)
                if src is None and parent and not (by.startswith("owner:") and subj != self.one(
                        "SELECT subject FROM item WHERE key=? ORDER BY gen DESC LIMIT 1", (parent,))):
                    # a next step opened in the same write as the close it follows carries that close's pair; for his
                    # channels only on the subject of the question he answered
                    pair = (self.one("SELECT source FROM move WHERE key=? AND verb='close' AND at=? AND by=?", (parent, mat, by)), parent)
                elif src is None and verb == "close":     # a cascade close carries the pair of the close that caused it
                    cause = self._cascade_cause(key, mat, why or "")
                    if cause:
                        pair = (self.one("SELECT source FROM move WHERE key=? AND verb='close' AND at=? AND by=?", (cause, mat, by)), cause)
                if pair not in logs.get(by, ()):
                    bad.append(("move", seq, pair))
            if verb == "close" and ends == "dropped" and (why or "").startswith("subject gone"):
                kind, subj, home = self.con.execute("SELECT kind, subject, home FROM item WHERE key=? ORDER BY (closed_at = ?) DESC, gen DESC LIMIT 1", (key, mat)).fetchone()
                if kind != "work":      # a lane's own work is dropped on an outside fact (its copy is gone); anything else needs its lane closed
                    live = self.one("SELECT count(*) FROM item WHERE kind='work' AND subject=? AND home=? AND opened_at<=? AND (closed_at IS NULL OR closed_at>?)",
                                    (subj, home, mat, mat))
                    gone = self.one("SELECT count(*) FROM item WHERE kind='work' AND subject=? AND home=? AND closed_at<=?", (subj, home, mat))
                    if live or not gone:
                        bad.append(("drop", seq, (src, key)))
            elif verb == "hand" and by == "tick" and not ((src or "").startswith("clock-leap:")
                                                        and self.one("SELECT 1 FROM move WHERE key=? AND at=? AND source=?", (CLOCK_ALERT, mat, "clock@%d" % mat))):
                bad.append(("hand", seq, (src, key)))           # the tick hands only at a clock leap, in the same write as the alert's open or note
            elif verb == "close" and ends == "dropped" and (why or "").startswith("ended:") and by == "tick":
                if (self.one("SELECT due_at FROM item WHERE key=? AND closed_at=?", (key, mat)) or 0) > mat:
                    bad.append(("drop", seq, (src, key)))
        for pj, v, src, by in self.con.execute("SELECT project, version, source, set_by FROM policy"):
            if (src, "policy:" + pj) not in logs.get(by, ()):
                bad.append(("policy", "%s v%d" % (pj, v), (src, "policy:" + pj)))
        for what, ref, pair in bad:
            k = "security:fleet/forged-%s-%s" % (what, re.sub(r"\W+", "-", str(ref)))
            if not self.seen("forged:%s:%s" % (what, ref)):
                self._write([dict(at=at, verb="open", key=k, kind="security", home="main", subject="stamp", by="adapter:stamp-check",
                                  source="forged:%s:%s" % (what, ref), holder="main", holder_id="main", due_at=at + 900, page="main",
                                  why="a stamp its channel's log does not hold, or a drop whose reason is not true: %s %s %r" % (what, ref, pair))])
        self.con.execute("INSERT INTO cursor VALUES('stamp-check', ?) ON CONFLICT(reader) DO UPDATE SET seq=excluded.seq", (top,))
        return bad
