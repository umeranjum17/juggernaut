"""Opening the host's one item store: used by jg-item and by every adapter, so all of them find the same file, open it
the same way and stamp the same clock frame. Python stdlib only.

    import sys; sys.path.insert(0, "<copy>/core/item-store")
    import itemdb
    st = itemdb.open_db(home, "owner:chat")      # home: the JG_HOME directory; by: this writer's fixed stamp
    at = itemdb.stamp(st)                         # before each write: the host clock, and the frame the move carries
    st.open(at, key, kind, home_id, subject, owes, st.me, source=message_id)

A Store opened here also refuses, on every write (rung 1, for jg-item and every adapter alike):
  - a move stamped otherwise than its `by` (open with by=None only for the tick and the checks);
  - a write none of whose moves names a source, unless the tick writes it: the pair (source, item key) is what makes
    a call run twice write once, so a write without one could repeat (the next steps and blocker closes written in
    the same write as a sourced move carry its pair, as the stamp check reads them);
  - an open whose key does not have its kind's shape (keys.py: the one key, subject and project contract);
  - an open of a kind whose first holder the opener names (alert, wait, steer, blocker) with no `named=`.
or_intake() turns a refused adapter write, or any other error in it, into one intake item, so nothing is lost behind a
caller's `|| true` (docs/item-store.md)."""
import hashlib, os, re, subprocess, time

import keys as K
import store as S

MARKER = ".jg-squad-lead-home"
PARENT = ".jg-squad-lead-parent"


class Unbound(Exception):
    """A home's parent binding names no home, or the bindings loop."""


def main_home(home):
    """Follow each Squad Lead home's parent binding (`parent_home=<path>`) to the home that has none: the main home."""
    home, seen = os.path.realpath(home), []
    while True:
        seen.append(home)
        try:
            lines = open(os.path.join(home, PARENT), encoding="utf-8").read().splitlines()
        except OSError:
            return home
        parent = next((ln.split("=", 1)[1].strip() for ln in lines if ln.startswith("parent_home=")), "")
        if not parent or not os.path.isdir(parent):
            raise Unbound("%s names no parent home directory" % os.path.join(home, PARENT))
        home = os.path.realpath(parent)
        if home in seen or len(seen) > 8:
            raise Unbound("the parent bindings loop at %s" % home)


def home_id(home):
    """'main' for the main home; else the first line of the home's .jg-squad-lead-home (for example crewhouse)."""
    try:
        first = open(os.path.join(home, MARKER), encoding="utf-8").readline().strip()
    except OSError:
        return "main"
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", first):
        raise Unbound("%s does not hold a home id on its first line" % os.path.join(home, MARKER))
    return first


def store_dir(home):
    return os.path.join(main_home(home), "state", "item-store")


def db_path(home):
    return os.path.join(store_dir(home), "fleet.db")


def boot_id():
    try:
        raw = open("/proc/sys/kernel/random/boot_id").read().strip()
    except OSError:
        try:
            raw = subprocess.run(["sysctl", "-n", "kern.boottime"], capture_output=True, text=True, check=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            raw = "unknown"
    return re.sub(r"\W+", "-", raw).strip("-") or "unknown"     # the frame is <boot id>:<offset>: no ":" inside the id


def steady():
    return time.clock_gettime(time.CLOCK_BOOTTIME) if hasattr(time, "CLOCK_BOOTTIME") else time.monotonic()


class ProdStore(S.Store):
    """The store as every writer on the host opens it: the two refusals above, then the store's own rules."""

    def _write(self, rows):
        if rows and not any(r.get("source") for r in rows) and rows[0].get("by") != "tick":
            raise S.Refused("source: every write names its outside record (--source); only the tick's own moves have none")
        for r in rows:
            if r.get("verb") == "open":
                K.check(r.get("kind"), r.get("key"), r.get("home"), r.get("subject"))
        return super()._write(rows)

    def open(self, at, key, kind, home, subject, owes, by, source=None, named=None, **kw):
        if kind in self.kind and self.kind[kind][1] == "named" and named is None and not self.item(key):
            raise S.Refused("holder: a %s item's opener names its first holder (named=worker, lead, main or outside)" % kind)
        return super().open(at, key, kind, home, subject, owes, by, source=source, named=named, **kw)


def open_db(home, by):
    """The one way to open the store. The schema runs once, when the file is created; after that the file is attached
    (Store(path) on an existing file fails). WAL and a 10 s busy wait, because every home of the host writes it."""
    d = store_dir(home)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "fleet.db")
    st = ProdStore(path, me=by, attach=os.path.exists(path))
    st.con.execute("PRAGMA busy_timeout=10000")
    st.con.execute("PRAGMA journal_mode=WAL")
    st.shipped = S.Store(":memory:").schema_hash()       # the rules as shipped in schema.sql, for the audit
    st.boot = boot_id()
    return st


def stamp(st):
    """Before each write: the host clock (epoch s) and the frame offset (host clock minus the steady clock). Returns at."""
    at, sd = int(time.time()), steady()
    st._off[0] = at - int(sd)
    st._host = at
    st._steady = int(sd)
    return at


def or_intake(st, at, source, home, subject, call, *args, **kw):
    """Run one store call with its source; when the store refuses it, or the call fails in any other way, open one
    intake item for Main in the same home, keyed by that source, naming the refusal or the error. The expand phase's
    adapters call every write this way, so a refused write is listed on Main's board, never lost. A call with no source
    (which the store refuses) is keyed by the call itself. Returns the call's result; 'intake' when it opened the
    intake item, 'again' when that item was already written for this source. Only a failure of the intake write itself
    is raised."""
    try:
        return call(*args, source=source, **kw)
    except Exception as e:      # a refusal, or any other error: never lost behind a caller's `|| true`
        tag = source or "no-source:" + hashlib.sha256(repr((getattr(call, "__name__", "call"), [x for x in args if x != at],
                                                             sorted(kw.items()))).encode()).hexdigest()[:12]
        why = str(e) if isinstance(e, S.Refused) else "%s: %s" % (type(e).__name__, e)
        key = "intake:%s/refused-%s" % (home, hashlib.sha256(tag.encode()).hexdigest()[:12])
        r = st.open(at, key, "intake", home, subject, ("place this refused write (%s): %s" % (tag, why))[:300], st.me,
                    source="refused:" + tag)
        return "intake" if r == "open" else r


def task_ref(home, task):
    """(ticket, project) of a task, from its record <home>/state/<task>.meta: `ticket=` (else the task id itself) and
    the last part of `project=` (the project's clone path; else None: the caller names the project)."""
    ticket, project = task, None
    try:
        for ln in open(os.path.join(home, "state", task + ".meta"), encoding="utf-8"):
            k, _, v = ln.rstrip("\n").partition("=")
            if k == "ticket" and v:
                ticket = v
            elif k == "project" and v:
                project = os.path.basename(v.rstrip("/"))
    except OSError:
        pass
    return ticket, project
