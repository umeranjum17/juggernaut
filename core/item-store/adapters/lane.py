#!/usr/bin/env python3
"""The lane adapter (stamp adapter:status): every status line of every lane also writes the item store, by the word
table below. The status files stay the workers' interface and stay authoritative until the switch: nothing decides from
the store yet, and `compare` measures how far the two agree.

  lane.py read <status file>     the lines past the file's byte cursor, one row each; a second run with nothing new writes nothing
  lane.py scan <home>            `read` on every <home>/state/*.status (never parent-replies.status, a channel, not a lane)
  lane.py import <home>          the home's one-time cut-over: work, and each wait open today, for every task record whose newest line is
                                 not done or failed (source import:<home id>/<task>); the byte cursor of every status file that has none
                                 goes to its end, so the history before the cut-over is never replayed; a second run writes nothing
  lane.py is-open <home id> <task> <wait key>      exit 0 when wait:<home id>/<task>#<key> is open, 1 when not, 2 when the store cannot answer
  lane.py has-open <item key>    exit 0 when that item is open, 1 when not, 2 when the store cannot answer
  lane.py compare <home>         today's records against the store, one line per difference, exit 1 when any (a finished lane waits for nothing)

Each line maps to the first row that matches (the replay's table, frozen/final/probe/replay_c.py on_worker_line):
 0 any line, while worker-stopped:<home>/<ticket> is open: that alert closes done (the worker wrote again)
 1 a task with no record state/<task>.meta: intake:<home>/<task> (Main, 1 h), later lines a note on it
 2 the first line of a task with a record and no work ever: its work opens (parent its open dispatch), then the line's own row;
   when the store refuses that work (no policy row, lane limit) the line goes to the task's intake item instead
 3 done on open work: the work closes done; in the same write a ship's land (its head), a Recon's report, every lane's cleanup
 3b done of a ship whose project's land is the owner's (tight): no land; wait:<task>#land-word on Main (30 min) instead
 4 done or failed on closed work: no move (counted)
 5 failed on open work: handed to the lead (Main in the main home)
 6 blocked, needs-decision or paused with wait=owner|captain, or captain-held: wait on Main (30 min), never the owner
 7 paused with no wait=: no move, counted as refused ("a wait must name who owes the next move")
 8 paused with wait=worker: a note on the work
10 waits-for: <ticket>: blocker waits-for:<home>/<task>#<ticket> on that ticket's open work, land or merge (the lead, 2 h);
   with none open, a dispatch for that ticket (the lead, 24 h)
 9 blocked, needs-decision or paused with wait=lead|main|outside|tick or no wait: wait:<home>/<task>#<key> (a second line a note);
   lead -> the lead, main or none -> Main, outside and tick -> outside, due at `until <time>` (at least 60 s) else 1 day
11 resolved with key=<k> and that wait open: the wait closes done (answer:<text>)
12 resolved with a key that names no open wait, or with no key on closed work: no move (counted)
13 resolved with no key on open work: a note on the work
14 working, progress or any other word on open work: a note on the work
15 working or progress on work closed done: a new work with the same key (rework)
(row 10 is tried before row 9, which would otherwise take every blocked line.)

Its own record, <main home>/state/item-store/status-written.log, takes one `<source>\\t<item key>` line per write (a line with
no move: `<source>\\tno move: <why>`; a row 7 line: `<source>\\trefused: no wait holder`), and logs/adapter-status prints it for
the tick's stamp check. Every write goes through itemdb.or_intake: a refused write is one intake item on Main, never lost."""
import calendar, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.realpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(HERE, ".."))
import itemdb   # noqa: E402
import keys as K   # noqa: E402
import store as S   # noqa: E402

BY = "adapter:status"
LINE = re.compile(r"^([a-z][a-z-]*)\b")
TAG = re.compile(r"\[(\w[\w-]*)=([^\]]*)\]")
UNTIL = re.compile(r"until (\d{4}-\d\d-\d\dT\d\d:\d\dZ)")
WAITS_FOR = re.compile(r"^\s*waits-for:\s*(\S+)")
DONE_WORDS = ("done", "failed")
WAIT_VERBS = ("blocked", "needs-decision", "paused")
DAY = 86400


def slug(k):
    """A wait key as the store's key shape takes it (a valid key is unchanged)."""
    return re.sub(r"^[^A-Za-z0-9]+", "", re.sub(r"[^A-Za-z0-9._-]+", "-", k or "")) or "default"


def parse(ln):
    """(verb, tags, text) of one status line, as the replay reads it."""
    m = LINE.match(ln)
    head, sep, tail = ln.partition("]:")
    tags = dict(TAG.findall(head + "]" if sep else ln))        # the tags are before the first "]:", the last one's bracket included
    return (m.group(1) if m else "?"), tags, (tail if sep else ln).strip()


def meta_get(home, task, field):
    try:
        for ln in open(os.path.join(home, "state", task + ".meta"), encoding="utf-8"):
            k, _, v = ln.rstrip("\n").partition("=")
            if k == field:
                return v
    except OSError:
        pass
    return None


def cursor_path(home, hid, task):
    return os.path.join(itemdb.store_dir(home), "cursors", "%s.%s" % (hid, task))


def read_cursor(home, hid, task):
    try:
        return int(open(cursor_path(home, hid, task)).read().strip() or 0)
    except (OSError, ValueError):
        return None


def write_cursor(home, hid, task, off):
    p = cursor_path(home, hid, task)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".tmp", "w") as fh:
        fh.write("%d\n" % off)
    os.replace(p + ".tmp", p)


class Lane:
    """One home's adapter session: the store, the home and the lines written, shared by every task read in it."""

    def __init__(self, home):
        self.home = os.path.realpath(home)
        self.hid = itemdb.home_id(self.home)
        self.st = itemdb.open_db(self.home, BY)
        self.logfile = os.path.join(itemdb.store_dir(self.home), "status-written.log")
        self.pending = []

    # ---------------------------------------------------------------- one line
    def put(self, key, call, *args, **kw):
        """One write of the current line: through or_intake (a refusal is one intake item on Main); its pair is logged."""
        r = itemdb.or_intake(self.st, self.at, self.src, self.hid, self.ticket, call, self.at, *args, **kw)
        self.pending.append((self.src, key))
        return r

    def say(self, why):
        self.pending.append((self.src, why))

    def flush(self):
        refused = self.st.one("SELECT key FROM move WHERE source=? LIMIT 1", ("refused:" + self.src,)) if self.src else None
        if refused:      # or_intake's own intake item is stamped by this adapter, so the stamp check reads it here
            self.pending.append(("refused:" + self.src, refused))
        if self.pending:
            os.makedirs(os.path.dirname(self.logfile), exist_ok=True)
            with open(self.logfile, "a", encoding="utf-8") as fh:
                fh.write("".join("%s\t%s\n" % p for p in self.pending))
        self.pending = []

    def intake(self, text):
        key = "intake:%s/%s" % (self.hid, self.task)       # one per task: a second line is a note on it
        return self.put(key, self.st.open, key, "intake", self.hid, self.ticket, text[:300], BY)

    def open_work(self, owes, opens_alone=False):
        """The task's work item; (True, '') or (False, the store's refusal). A work opened for a line that also writes its own row
        names a source of its own: the pair (source, key) is written once, so the line's note on the same key would be 'again'."""
        src = self.src if opens_alone else self.src + "+work"
        parent = None
        try:         # a critic's work is the child of its Recon's (data/<task>/assignment.tsv, written by jg-recon-handoff.sh assign)
            recon = open(os.path.join(self.home, "data", self.task, "assignment.tsv"), encoding="utf-8").readline().split("\t")[0].strip()
            parent = K.key("work", self.hid, task=recon) if recon else None
        except (OSError, ValueError):
            pass
        if not (parent and self.st.item(parent)):
            parent = "dispatch:%s/%s" % (self.hid, self.ticket)
            parent = parent if self.st.item(parent) else None
        try:
            self.st.open(self.at, self.wk, "work", self.hid, self.ticket, owes, BY, source=src, lane=self.wid,
                         project=self.project, parent=parent)
        except Exception as e:
            return False, str(e) if isinstance(e, S.Refused) else "%s: %s" % (type(e).__name__, e)
        self.pending.append((src, self.wk))
        return True, ""

    def line(self, task, ln, off):
        verb, tags, text = parse(ln)
        st, hid = self.st, self.hid
        self.task, self.src = task, "status:%s/%s@%d" % (hid, task, off)
        self.ticket, self.project = itemdb.task_ref(self.home, task)
        self.wk, self.wid = K.key("work", hid, task=task), "worker:%s/%s" % (hid, task)
        self.at = itemdb.stamp(st)
        what = ("%s: %s" % (verb, text))[:200]
        alert = S.Store.alert_key("worker-stopped", hid, self.ticket)
        if st.item(alert):                                                                       # row 0
            self.put(alert, st.close, alert, "done", "gone: the worker wrote again", BY)
        if not os.path.exists(os.path.join(self.home, "state", task + ".meta")):                  # row 1
            return self.intake("a lane with no record wrote " + what)
        if not st.one("SELECT 1 FROM item WHERE key=?", (self.wk,)):                              # row 2
            ok, why = self.open_work("the lane's task")
            if not ok:
                return self.intake("the work of this lane could not open (%s); it wrote %s" % (why, what))
        it = st.item(self.wk)
        if verb in DONE_WORDS:
            if not it:
                return self.say("no move: a repeat %s on closed work" % verb)                    # row 4
            return self.done(tags, text) if verb == "done" else self.failed(it, text)
        owner = tags.get("wait") in ("owner", "captain") or "captain-held" in ln
        if verb in WAIT_VERBS and not owner and verb == "paused" and not tags.get("wait"):        # row 7
            self.pending.append((self.src, "refused: no wait holder"))
            return
        if verb in WAIT_VERBS and verb == "paused" and tags.get("wait") == "worker" and not owner:   # row 8
            return self.put(self.wk, st.note, self.wk, BY, text[:200] or verb) if it else self.say("no move: own wait on closed work")
        if verb in WAIT_VERBS:
            return self.wait(verb, tags, text, ln, owner)                                        # rows 6, 9, 10
        if verb == "resolved":
            return self.resolved(it, tags, text)
        if it:                                                                                   # row 14
            return self.put(self.wk, st.note, self.wk, BY, text[:200] or verb)
        if verb in ("working", "progress"):                                                      # row 15
            ok, why = self.open_work("rework after done", opens_alone=True)
            return None if ok else self.intake("rework could not open (%s); it wrote %s" % (why, what))
        return self.say("no move: %s on closed work" % verb)

    def receipt_head(self, task):
        try:
            import json
            return json.load(open(os.path.join(self.home, "state", task + ".run-receipt.json"))).get("head")
        except (OSError, ValueError):
            return None

    def done(self, tags, text):                                                                  # rows 3 and 3b
        st, hid, task, ticket = self.st, self.hid, self.task, self.ticket
        recon = meta_get(self.home, task, "kind") == "scout"
        steps = []
        if recon:
            proof = "report:" + (tags.get("report") or os.path.join(self.home, "data", task, "report.md"))
            steps.append(dict(key=K.key("report", hid, task=task), kind="report", home=hid, subject=ticket,
                              owes="act on the finished Recon: " + (text[:120] or task)))
        else:
            proof = "receipt:" + (tags.get("receipt") or (task + ".run-receipt.json" if self.receipt_head(task) else "the done line"))
            head = tags.get("head") or self.receipt_head(task) or "done-%d" % int(self.src.rsplit("@", 1)[1])
            lk = K.key("land", hid, ticket=ticket, head=head)
            if st.one("SELECT land FROM v_policy WHERE project=?", (self.project,)) == "owner":
                steps.append(dict(key=K.key("wait", hid, task=task, wait="land-word"), kind="wait", home=hid, subject=ticket, named="main", due=1800,
                                  owes="ask the owner to land %s: `jg-item open question:land:%s/%s@%s --kind question --options 'yes|no'`"
                                       % (head, hid, ticket, head)))
            else:
                steps.append(dict(key=lk, kind="land", home=hid, subject=ticket, project=self.project, owes="land the proved commit " + head))
        steps.append(dict(key=K.key("cleanup", hid, task=task), kind="cleanup", home=hid, subject=ticket, owes="return the finished lane's copy"))
        try:                       # a refused next step (an open question on the ticket) never keeps the lane's work open
            st.close(self.at, self.wk, "done", proof, BY, source=self.src, then=steps)
            self.pending.append((self.src, self.wk))
        except S.Refused as e:
            rest = [s for s in steps if s["kind"] != "land"]
            if len(rest) == len(steps):
                return self.put(self.wk, st.close, self.wk, "done", proof, BY, then=steps)
            self.put(self.wk, st.close, self.wk, "done", proof, BY, then=rest)
            self.intake("the land of %s could not open (%s)" % (steps[0]["key"], e))

    def failed(self, it, text):                                                                  # row 5
        st = self.st
        why = "failed: " + (text[:200] or "no text")
        if it["holder"] != "worker":
            return self.put(self.wk, st.note, self.wk, BY, why)
        h = "main" if self.hid == "main" else "lead"
        hid = "main" if self.hid == "main" else "lead:" + self.hid
        lane = st.as_(self.wid)       # the lane's own worker hands its work on: only its holder may
        return self.put(self.wk, lane.hand, self.wk, h, hid, st.rung_limit(h, self.project), why, self.wid)

    def wait(self, verb, tags, text, ln, owner):                                                 # rows 6, 10, 9
        st, hid = self.st, self.hid
        k = slug(tags.get("key") or ("pause" if verb == "paused" else "default"))
        key = K.key("wait", hid, task=self.task, wait=k)
        wf = WAITS_FOR.match(text)
        if owner:
            return self.put(key, st.open, key, "wait", hid, self.ticket, ("turn this into one owner question or answer it: " + text)[:300],
                            BY, named="main", lane=self.wid, due=1800)
        if wf:
            return self.waits_for(wf.group(1), text)
        w = tags.get("wait")
        named = {"lead": "lead", "main": "main", "outside": "outside", "tick": "outside"}.get(w, "main")
        due, mu = None, UNTIL.search(ln)
        if named == "outside":
            due = max(60, calendar.timegm(time.strptime(mu.group(1), "%Y-%m-%dT%H:%MZ")) - self.at) if mu else DAY
        self.put(key, st.open, key, "wait", hid, self.ticket, text[:300] or verb, BY, named=named, lane=self.wid, due=due)

    def waits_for(self, other, text):                                                            # row 10
        st, hid = self.st, self.hid
        parent = st.one("SELECT key FROM item WHERE state='open' AND subject=? AND kind IN ('work','land','merge') "
                        "ORDER BY CASE kind WHEN 'work' THEN 0 WHEN 'land' THEN 1 ELSE 2 END LIMIT 1", (other,))
        if parent:
            key = "waits-for:%s/%s#%s" % (hid, self.task, slug(other))
            return self.put(key, st.open, key, "blocker", hid, self.ticket, text[:300], BY, named="lead", parent=parent, due=7200)
        key = K.key("dispatch", hid, ticket=other)
        self.put(key, st.open, key, "dispatch", hid, other, ("start %s: %s waits for it (%s)" % (other, self.ticket, text))[:300], BY)

    def resolved(self, it, tags, text):                                                          # rows 11 to 13
        st = self.st
        k = tags.get("key")
        if k:
            key = K.key("wait", self.hid, task=self.task, wait=slug(k))
            if st.item(key):
                return self.put(key, st.close, key, "done", "answer:" + (text[:150] or "resolved"), BY)
            return self.say("no move: resolved names no open wait")
        if it:
            return self.put(self.wk, st.note, self.wk, BY, ("resolved: " + text)[:200])
        self.say("no move: a keyless resolved on closed work")

    # ---------------------------------------------------------------- one file, one home
    def read(self, path):
        task = os.path.basename(path)[:-len(".status")]
        off = read_cursor(self.home, self.hid, task) or 0
        try:
            with open(path, "rb") as fh:
                fh.seek(off)
                data = fh.read()
        except OSError:
            return
        end = off
        try:
            for raw in data.split(b"\n")[:-1]:               # the last chunk is a line still being written: the next run reads it whole
                ln = raw.decode("utf-8", "replace").rstrip("\r")
                if ln.strip():
                    self.line(task, ln, end)
                    self.flush()
                end += len(raw) + 1
        finally:
            if end != off:
                write_cursor(self.home, self.hid, task, end)

    def scan(self):
        sd = os.path.join(self.home, "state")
        for name in sorted(os.listdir(sd)) if os.path.isdir(sd) else []:
            if name.endswith(".status") and name != "parent-replies.status":
                self.read(os.path.join(sd, name))

    def newest_verb(self, path):
        verb = None
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for ln in fh:
                    if ln.strip():
                        verb = parse(ln.rstrip("\n"))[0]
        except OSError:
            pass
        return verb

    def import_home(self):
        sd = os.path.join(self.home, "state")
        for name in sorted(os.listdir(sd)) if os.path.isdir(sd) else []:
            if name.endswith(".status") and name != "parent-replies.status":
                task = name[:-len(".status")]
                if read_cursor(self.home, self.hid, task) is None:
                    write_cursor(self.home, self.hid, task, os.path.getsize(os.path.join(sd, name)))
        for name in sorted(os.listdir(sd)) if os.path.isdir(sd) else []:
            if not name.endswith(".meta"):
                continue
            task = name[:-len(".meta")]
            if self.newest_verb(os.path.join(sd, task + ".status")) in DONE_WORDS:
                continue
            self.task, self.src = task, "import:%s/%s" % (self.hid, task)
            self.ticket, self.project = itemdb.task_ref(self.home, task)
            self.wk, self.wid = K.key("work", self.hid, task=task), "worker:%s/%s" % (self.hid, task)
            self.at = itemdb.stamp(self.st)
            if not self.st.one("SELECT 1 FROM item WHERE key=? AND state='open'", (self.wk,)):
                self.put(self.wk, self.st.open, self.wk, "work", self.hid, self.ticket, "the lane's task (imported at the cut-over)", BY,
                         lane=self.wid, project=self.project)
            self.open_waits(os.path.join(sd, task + ".status"))
            self.flush()

    def open_waits(self, path):
        """The waits open today in one status file, each opened as its last wait line opens it (rows 6, 9, 10); one already open stays."""
        for k, (verb, tags, text, ln, wf) in sorted(self.fold(path).items()):
            if not self.wait_open(self.task, k, wf):
                self.wait(verb, tags, text, ln, tags.get("wait") in ("owner", "captain") or "captain-held" in ln)

    def wait_open(self, task, k, wf):
        """Whether the store holds the wait today's fold leaves open under key k; a waits-for line is a blocker, or a dispatch for its ticket."""
        st, hid = self.st, self.hid
        if wf:
            return bool(st.one("SELECT 1 FROM item WHERE state='open' AND home=? AND (key LIKE ? OR key=?)",
                               (hid, "waits-for:%s/%s#%%" % (hid, task), K.key("dispatch", hid, ticket=wf))))
        return bool(st.one("SELECT 1 FROM item WHERE state='open' AND kind='wait' AND home=? AND key=?", (hid, K.key("wait", hid, task=task, wait=k))))

    # ---------------------------------------------------------------- compare
    def fold(self, path):
        """The waits today's fold leaves open in one status file (bin/jg-classify-lib.sh), by the key the store gives them:
        (verb, tags, text, line, the ticket a waits-for line waits for or None) of each one's last wait line."""
        rows = []
        for fn in ("status_open_decisions", "status_open_activities"):       # one process each: the library may end its shell
            out = subprocess.run(["bash", "-c", '. "$1/bin/jg-classify-lib.sh"; "$2" "$3"', "_", ROOT, fn, path],
                                 capture_output=True, text=True, env=dict(os.environ, JG_HOME=self.home))
            rows += out.stdout.splitlines()
        last = {}
        try:
            for ln in open(path, encoding="utf-8", errors="replace"):
                v, tags, text = parse(ln.rstrip("\n"))
                if v in WAIT_VERBS:
                    last[slug(tags.get("key") or ("pause" if v == "paused" else "default"))] = (v, tags, text, ln.rstrip("\n"))
        except OSError:
            pass
        keys = {}
        for row in rows:
            f = row.split("\t")
            if len(f) >= 2 and f[1] in WAIT_VERBS:           # the activities list also holds the lane's working line, which waits for nothing
                k = slug(f[0])
                if f[1] == "paused" and k == "default":
                    k = "pause"
                v, tags, text, ln = last.get(k, (f[1], {}, "", f[1]))
                if v == "paused" and tags.get("wait") in (None, "", "worker"):
                    continue                                    # a note on the work (row 8) or a refused line (row 7): no wait item
                m = WAITS_FOR.match(text)
                keys[k] = (v, tags, text, ln, m.group(1) if m else None)
        return keys

    def compare(self):
        st, hid, sd, diffs = self.st, self.hid, os.path.join(self.home, "state"), []
        tasks = sorted(n[:-len(".meta")] for n in os.listdir(sd) if n.endswith(".meta")) if os.path.isdir(sd) else []
        for task in tasks:
            sf = os.path.join(sd, task + ".status")
            if not os.path.exists(sf):
                continue
            if self.newest_verb(sf) not in DONE_WORDS + (None,) and not st.item(K.key("work", hid, task=task)):
                diffs.append("%s work today=open store=closed" % task)
            want = {} if self.newest_verb(sf) in DONE_WORDS else self.fold(sf)       # a finished lane waits for nothing: its done closed them
            have = {r[0].split("#", 1)[1] for r in st.con.execute(
                "SELECT key FROM item WHERE state='open' AND kind='wait' AND home=? AND key LIKE ?", (hid, "wait:%s/%s#%%" % (hid, task)))}
            for k, row in sorted(want.items()):
                if not self.wait_open(task, k, row[4]):
                    diffs.append("%s wait#%s today=open store=closed" % (task, k))
            for k in sorted(have - set(want)):
                diffs.append("%s wait#%s today=closed store=open" % (task, k))
        for name in sorted(os.listdir(sd)) if os.path.isdir(sd) else []:
            d = os.path.join(sd, name)
            if not (name.endswith(".inbox") and os.path.isdir(d)):
                continue
            task = name[:-len(".inbox")]
            if not os.path.exists(os.path.join(sd, task + ".meta")):
                continue          # a gone lane's leftover inbox: nobody reads it, so no steer waits there
            for f in sorted(os.listdir(d)):
                if re.fullmatch(r"\d+\.msg", f) and os.path.isfile(os.path.join(d, f)):
                    key = K.key("steer", hid, task=task, n=str(int(f[:-4])))
                    if not st.item(key):
                        diffs.append("%s steer#%d today=open store=closed" % (task, int(f[:-4])))
        return diffs


def need_store_file(home):
    return os.path.exists(itemdb.db_path(home))


def main(argv):
    if not argv:
        print("usage: lane.py read|scan|import|is-open|has-open|compare ...", file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "read" and len(args) == 1 and args[0].endswith(".status"):
            f = os.path.realpath(args[0])
            Lane(os.path.dirname(os.path.dirname(f))).read(f)
        elif cmd in ("scan", "import", "compare") and len(args) == 1:
            ln = Lane(args[0])
            if cmd == "compare":
                diffs = ln.compare()
                print("\n".join(diffs)) if diffs else None
                return 1 if diffs else 0
            ln.scan() if cmd == "scan" else ln.import_home()
        elif cmd in ("is-open", "has-open"):
            home = os.environ.get("JG_HOME")
            if not home or not need_store_file(home):
                return 2
            st = itemdb.open_db(home, BY)
            if cmd == "has-open" and len(args) == 1:
                return 0 if st.item(args[0]) else 1
            if cmd == "is-open" and len(args) == 3:
                k = args[2]
                ks = ["default", "pause"] if k == "default" else [slug(k)]
                return 0 if any(st.item(K.key("wait", args[0], task=args[1], wait=x)) for x in ks) else 1
            return 2
        else:
            print("usage: lane.py read <status file> | scan <home> | import <home> | compare <home> | is-open <home id> <task> <key> | has-open <key>", file=sys.stderr)
            return 2
    except Exception as e:       # the real cause, never a trace into a worker's pipe
        print("lane.py: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 2 if cmd in ("is-open", "has-open") else 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
