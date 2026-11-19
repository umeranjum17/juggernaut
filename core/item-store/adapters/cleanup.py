#!/usr/bin/env python3
"""The cleanup adapter (stamp adapter:cleanup): a finished lane's copy is returned by the guarded cleanup without anyone
asking, and a refusal is the lead's item with its reason. The landed-work test (hard rule 3) stays in bin/jg-teardown.sh and
its Go core: this adapter never judges landing, it runs the script and records the answer. An update closes when git shows
the home runs the released tip.

  run <home id> <task> --source cleanup:<task>
      Runs bin/jg-teardown.sh <task> once for the open cleanup:<home id>/<task> item. Success closes it done `cleaned:<task>`;
      a refusal (unlanded work, uncommitted work, a Recon with no report) is a note carrying the script's reason, and the item
      stays with the lead. A copy already gone (no state/<task>.meta) closes it done too: nothing is left to return.
  update <home id> <home path> <release commit> --source update:<home id>@<release commit>
      Closes update:<home id>@<release commit> done `home-at:<home HEAD>` when the release commit is HEAD or under it, or when
      a commit under HEAD has the release commit's git patch-id (a re-cut release); otherwise the item stays open and climbs.
  sweep
      `run` for each open cleanup item of this home with no cleanup note in the last hour, and `update` for each open update
      item (each home's path from core/item-store/homes.sh). Prints nothing. The item-store-sweep check calls it.
  compare <home>
      A finished lane's copy against an open cleanup item, an open cleanup item against a copy on disk, and each update
      item against `git merge-base --is-ancestor` in its home: one line per difference, exit 1 when any.

  import <home>
      The cut-over: the cleanup item of each finished lane whose copy is still in <home> and that has none open (source
      import:<home id>/<task>). A second run changes nothing and says so.

Every write goes through itemdb.or_intake: a refused write is one intake item on Main. A call on an item that is no longer
open writes nothing and never runs the cleanup."""
import argparse, hashlib, os, re, subprocess, sys

HERE = os.path.dirname(os.path.realpath(__file__))
ITEM = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(ITEM))
sys.path.insert(0, ITEM)
import itemdb   # noqa: E402
import keys     # noqa: E402

STAMP = "adapter:cleanup"
HOUR = 3600
TEARDOWN_S = 900


class Session:
    def __init__(self, home=None):
        h = home or os.environ.get("JG_HOME")
        if not h or not os.path.isdir(h):
            sys.exit("cleanup.py: JG_HOME must name this home's directory")
        self.home = os.path.realpath(h)
        self.main = itemdb.main_home(self.home)
        self.hid = itemdb.home_id(self.home)
        self.st = itemdb.open_db(self.home, STAMP)

    def put(self, source, subject, call, *args, **kw):
        at = itemdb.stamp(self.st)
        return itemdb.or_intake(self.st, at, source, self.hid, subject, call, at, *args, **kw)


def git(d, *a, stdin=None):
    try:
        r = subprocess.run(["git", "-C", d] + list(a), capture_output=True, text=True, timeout=60, input=stdin)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def refusal(text):
    """The script's reason: its REFUSED lines, else the last few lines it printed."""
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    pick = [ln for ln in lines if "REFUSED" in ln or "refus" in ln.lower()] or lines[-3:]
    return (" | ".join(pick) or "the cleanup script refused with no output")[:280]


def copy_exists(home, task):
    return os.path.isfile(os.path.join(home, "state", task + ".meta"))


def teardown(home, task):
    env = dict(os.environ, JG_HOME=home)
    try:
        r = subprocess.run([os.path.join(ROOT, "bin", "jg-teardown.sh"), task], env=env, capture_output=True, text=True,
                           timeout=TEARDOWN_S)
    except (OSError, subprocess.SubprocessError) as e:
        return 1, "the cleanup script did not finish: %s" % e
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def do_run(s, hid, task, source):
    key = keys.key("cleanup", hid, task=task)
    if hid != s.hid or not s.st.item(key):
        return "closed"                      # nothing owes this cleanup: never run the script for it
    ticket, _ = itemdb.task_ref(s.home, task)
    if not copy_exists(s.home, task):
        return s.put(source, ticket, s.st.close, key, "done", "cleaned:%s (no copy left)" % task, STAMP)
    rc, out = teardown(s.home, task)
    if rc == 0:
        return s.put(source, ticket, s.st.close, key, "done", "cleaned:%s" % task, STAMP)
    why = ("cleanup refused (exit %d): %s" % (rc, refusal(out)))
    tag = hashlib.sha256(why.encode()).hexdigest()[:10]     # the same refusal twice is one note; a new reason is a new note
    return s.put("%s#%s" % (source, tag), ticket, s.st.note, key, STAMP, why)


def patch_id(d, commit):
    out = git(d, "show", "--format=", commit)
    pid = git(d, "patch-id", "--stable", stdin=out + "\n") if out else None
    return pid.split()[0] if pid else None


def home_at(path, release):
    """HEAD when it has the release under it or a commit with the release's patch-id; None when it does not (or git cannot tell)."""
    head = git(path, "rev-parse", "HEAD")
    if not head or git(path, "cat-file", "-e", release + "^{commit}") is None:
        return None
    if subprocess.run(["git", "-C", path, "merge-base", "--is-ancestor", release, "HEAD"], capture_output=True).returncode == 0:
        return head
    want = patch_id(path, release)
    if not want:
        return None
    log = git(path, "log", "--max-count=2000", "-p", "--format=commit %H", "HEAD")
    pids = git(path, "patch-id", "--stable", stdin=(log or "") + "\n") or ""
    return head if any(ln.split()[0] == want for ln in pids.splitlines() if ln.split()) else None


def do_update(s, hid, path, release, source):
    key = keys.key("update", hid, version=release)
    if not s.st.item(key):
        return "closed"
    head = home_at(path, release)
    if not head:
        return "open"
    return s.put(source, release, s.st.close, key, "done", "home-at:%s" % head, STAMP)


def homes(main):
    try:
        out = subprocess.run([os.path.join(ITEM, "homes.sh"), main], capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    return dict(ln.split("\t", 1) for ln in out.splitlines() if "\t" in ln)


def update_items(st, states):
    rows = st.con.execute("SELECT key, state FROM item WHERE kind='update' AND state IN (%s) ORDER BY key" % ",".join("?" * len(states)), states)
    for key, state in rows.fetchall():
        m = re.fullmatch(r"update:([^@]+)@(.+)", key)
        if m:
            yield m.group(1), m.group(2), state


def cmd_run(a):
    print(do_run(Session(), a.home_id, a.task, a.source))


def cmd_update(a):
    print(do_update(Session(), a.home_id, a.home_path, a.release, a.source))


def cmd_sweep(a):
    try:
        s = Session()
        at = itemdb.stamp(s.st)
        rows = s.st.con.execute("SELECT key FROM item WHERE kind='cleanup' AND state='open' AND home=? ORDER BY key", (s.hid,)).fetchall()
        for (key,) in rows:
            task = key.split("/", 1)[1]
            if s.st.one("SELECT 1 FROM move WHERE key=? AND verb='note' AND by=? AND at>?", (key, STAMP, at - HOUR)):
                continue
            do_run(s, s.hid, task, "cleanup:" + task)
        paths = homes(s.main)
        for hid, release, _ in list(update_items(s.st, ("open",))):
            if hid in paths:
                do_update(s, hid, paths[hid], release, "update:%s@%s" % (hid, release))
    except Exception as e:      # the sweep never breaks the check that runs it; today's records decide
        print("cleanup.py sweep: %s" % e, file=sys.stderr)


def newest_line(path):
    try:
        lines = [ln for ln in open(path, encoding="utf-8").read().splitlines() if ln.strip()]
    except OSError:
        return ""
    return lines[-1] if lines else ""


def uncleaned(s):
    """The tasks of the session's home that finished, whose copy is still here, and that have no open cleanup item."""
    state = os.path.join(s.home, "state")
    for name in sorted(os.listdir(state)) if os.path.isdir(state) else []:
        task = name[:-5]
        if name.endswith(".meta") and newest_line(os.path.join(state, task + ".status")).split(" ")[0] == "done" and \
                not s.st.item(keys.key("cleanup", s.hid, task=task)):
            yield task


def cmd_import(a):
    """A finished lane's cleanup item was opened by its done line; a lane that finished before the cut-over never had one."""
    s = Session(a.home)
    todo = list(uncleaned(s))
    for task in todo:
        ticket, _ = itemdb.task_ref(s.home, task)
        s.put("import:%s/%s" % (s.hid, task), ticket, s.st.open, keys.key("cleanup", s.hid, task=task), "cleanup", s.hid, ticket,
              "return the finished lane's copy", STAMP)
    there = s.st.one("SELECT count(*) FROM item WHERE kind='cleanup' AND state='open' AND home=?", (s.hid,)) - len(todo)
    print("cleanup import %s: opened %d, already open %d" % (s.hid, len(todo), there) if todo else
          "cleanup import %s: nothing to import (%d already open)" % (s.hid, there))


def cmd_compare(a):
    s, out = Session(), []
    for task in uncleaned(s):
        out.append("lane %s: finished, its copy is still here, and no cleanup item is open" % task)
    for (key,) in s.st.con.execute("SELECT key FROM item WHERE kind='cleanup' AND state='open' AND home=? ORDER BY key", (s.hid,)).fetchall():
        task = key.split("/", 1)[1]
        if not copy_exists(s.home, task):
            out.append("cleanup %s: open, and no copy is on disk" % key)
    paths = homes(s.main)
    for hid, release, st in update_items(s.st, ("open", "done")):
        if hid not in paths:
            continue
        at = home_at(paths[hid], release)
        if st == "open" and at:
            out.append("update %s@%s: open, but the home's HEAD %s already has the release" % (hid, release, at))
        elif st == "done" and not at:
            out.append("update %s@%s: closed, but the home's HEAD does not have the release" % (hid, release))
    for ln in out:
        print(ln)
    sys.exit(1 if out else 0)


def main(argv):
    p = argparse.ArgumentParser(prog="cleanup.py", description=__doc__.split("\n")[0])
    sp = p.add_subparsers(dest="cmd", required=True)

    def add(name, fn, *pos, source=False):
        sub = sp.add_parser(name)
        for x in pos:
            sub.add_argument(x)
        if source:
            sub.add_argument("--source", required=True)
        sub.set_defaults(fn=fn)
    add("run", cmd_run, "home_id", "task", source=True)
    add("update", cmd_update, "home_id", "home_path", "release", source=True)
    add("sweep", cmd_sweep)
    add("compare", cmd_compare, "home")
    add("import", cmd_import, "home")
    a = p.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main(sys.argv[1:])
