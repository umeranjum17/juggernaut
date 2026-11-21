#!/usr/bin/env python3
"""merge.py: each merge merge-on-green makes, as the `merge` step of its ticket (stamp adapter:merge; a red run's blocker is
stamped adapter:ci). It only records: today's rule in merge-on-green decides and the merge goes ahead whatever the store
says; a step the leash refuses is one intake item on Main (itemdb.or_intake), which slice 8d's gate counts. Every
subcommand prints the store's answer and exits 0 (compare: 1 on a difference; usage: 2).

  step <home id> <task id> <pull request> <head> --source mergeable:<pull request>@<head>
      Opens merge:<home id>/<ticket>@<n> (ticket and project from the task record); prints open, again or intake.
      A release pull request's record (kind=release, no ticket) is no merge step: it is the release step. It prints open
      when release:<project>@<n> is open; else, with merge=approved and merge_rule=<rule> in the record, it writes that
      standing word as his yes (owner.py answer --channel rules) and prints open (intake when no question is open); else
      it opens intake:<home id>/release-merge-<project>@<n> and prints intake.
  merged <home id> <task id> <pull request> <merge commit> --source merged:<pull request>@<head>
      Closes the step done `merged:<merge commit>` and its blockers with it (store.close); with no open step, one intake
      item. A release record writes nothing (jg-trunk.sh rollover closes the release step): prints release.
  red <home id> <ticket> <run id> --source ci:<run id>
      Opens blocker:<home id>/<ticket>#ci-<run id> (first holder the lead) under the ticket's open merge, land or release
      item; prints clear and writes nothing when none is open.
  compare <home>
      Merged pull requests (data/jg-merge-on-green/<task>.head, the forge's state) against done merge items, and open
      merge items against open pull requests; one line per difference, exit 1 when any. Release records are skipped.

Each write's pair is appended to <main home>/state/item-store/merge-written.log (core/item-store/logs/adapter-merge)."""
import argparse, os, re, subprocess, sys

HERE = os.path.dirname(os.path.realpath(__file__))
ITEM = os.path.dirname(HERE)
sys.path.insert(0, ITEM)
import itemdb   # noqa: E402
import keys as K   # noqa: E402

BY = "adapter:merge"
CI_BY = "adapter:ci"
PR_NUM = re.compile(r"(\d+)/?$")


def die(msg, code=1):
    print(msg, file=sys.stderr if code == 2 else sys.stdout)
    sys.exit(code)


def pr_number(pr):
    m = PR_NUM.search(pr)
    if not m:
        die("refused: %r names no pull request number" % pr, 2)
    return m.group(1)


def record(home, task):
    """The task's record as a dict (last value wins, as meta_get reads it); empty when it has none."""
    out = {}
    try:
        for ln in open(os.path.join(home, "state", task + ".meta"), encoding="utf-8"):
            k, _, v = ln.rstrip("\n").partition("=")
            out[k] = v
    except OSError:
        pass
    return out


class Session:
    def __init__(self, home_id_arg=None):
        h = os.environ.get("JG_HOME")
        if not h or not os.path.isdir(h):
            die("refused: JG_HOME must name this home's directory", 2)
        self.home = os.path.realpath(h)
        try:
            self.hid = itemdb.home_id(self.home)
        except itemdb.Unbound as e:
            die("refused: %s" % e, 2)
        if home_id_arg is not None and home_id_arg != self.hid:
            die("refused: home id %s is not this home's (%s)" % (home_id_arg, self.hid), 2)
        self.st = itemdb.open_db(self.home, BY)
        self.log = os.path.join(itemdb.store_dir(self.home), "merge-written.log")
        self.pairs = []

    def put(self, source, subject, key, call, *args, **kw):
        """One write through or_intake; its pair, and the refusal's intake pair, are logged."""
        at = itemdb.stamp(self.st)
        r = itemdb.or_intake(self.st, at, source, self.hid, subject, call, at, *args, **kw)
        self.pairs.append((source, key))
        refused = self.st.one("SELECT key FROM move WHERE source=? LIMIT 1", ("refused:" + source,))
        if r == "intake" and refused:
            self.pairs.append(("refused:" + source, refused))
        return r

    def flush(self):
        if self.pairs:
            os.makedirs(os.path.dirname(self.log), exist_ok=True)
            with open(self.log, "a", encoding="utf-8") as fh:
                fh.write("".join("%s\t%s\n" % p for p in self.pairs))
        self.pairs = []


def release_of(rec):
    """(project, pull request number) of a release record, else None."""
    if rec.get("kind") != "release":
        return None
    return os.path.basename(rec.get("project", "").rstrip("/")), pr_number(rec.get("pr", ""))


def cmd_step(a):
    s = Session(a.home_id)
    st = s.st
    rec = record(s.home, a.task)
    n, rel = pr_number(a.pull_request), release_of(rec)
    if rel:
        project, n = rel
        step = "release:%s@%s" % (project, n)
        if st.item(step):
            return print("open")
        if rec.get("merge") == "approved" and rec.get("merge_rule"):
            subprocess.run([sys.executable, "-I", os.path.join(HERE, "owner.py"), "answer", "--channel", "rules", "--message-id",
                                  "%s@%s" % (rec["merge_rule"], rec.get("pr_head", a.head)), "--key", "question:" + step, "--pick", "yes"],
                                 env=dict(os.environ, JG_HOME=s.home), capture_output=True, text=True)
            return print("open" if st.item(step) else "intake")
        key = "intake:%s/release-merge-%s@%s" % (s.hid, project, n)
        r = s.put(a.source, "%s@%s" % (project, n), key, st.open, key, "intake", s.hid, "%s@%s" % (project, n),
                  "release pull request %s merged with no yes of his in the store" % n, BY)
        s.flush()
        return print("intake" if r in ("open", "note", "intake") else r)
    ticket, project = itemdb.task_ref(s.home, a.task)
    key = K.key("merge", s.hid, ticket=ticket, pr=n)
    if st.seen(a.source, key):
        return print("again")
    if st.item(key):          # his yes already opened it
        return print("open")
    r = s.put(a.source, ticket, key, st.open, key, "merge", s.hid, ticket,
              "merge pull request %s of %s: today's rule merges it" % (n, ticket), BY, project=project)
    s.flush()
    print(r)


def cmd_merged(a):
    s = Session(a.home_id)
    st = s.st
    if release_of(record(s.home, a.task)):
        return print("release")
    ticket, _ = itemdb.task_ref(s.home, a.task)
    key = K.key("merge", s.hid, ticket=ticket, pr=pr_number(a.pull_request))
    if st.seen(a.source, key) or st.one("SELECT 1 FROM item WHERE key=? AND state='done'", (key,)):
        return print("again")
    if st.item(key):
        r = s.put(a.source, ticket, key, st.close, key, "done", "merged:" + a.commit, BY)
    elif st.one("SELECT 1 FROM move WHERE source LIKE ?", ("refused:mergeable:%s@%%" % pr_number(a.pull_request),)):
        return print("again")         # the step's refusal is already listed as one intake item: it is not listed twice
    else:
        ik = "intake:%s/merged-%s@%s" % (s.hid, ticket, pr_number(a.pull_request))
        r = s.put(a.source, ticket, ik, st.open, ik, "intake", s.hid, ticket,
                  "pull request %s merged as %s with no open merge step" % (pr_number(a.pull_request), a.commit), BY)
    s.flush()
    print(r)


def cmd_red(a):
    s = Session(a.home_id)
    st = s.st
    parent = st.one("SELECT key FROM item WHERE state='open' AND subject=? AND kind IN ('merge','land','release') ORDER BY id DESC LIMIT 1",
                    (a.ticket,))
    if not parent:
        return print("clear")
    key = "blocker:%s/%s#ci-%s" % (s.hid, a.ticket, a.run_id)
    at = itemdb.stamp(st)
    w = st.as_(CI_BY)
    r = itemdb.or_intake(w, at, a.source, s.hid, a.ticket, w.open, at, key, "blocker", s.hid, a.ticket,
                         "red CI run %s holds back %s" % (a.run_id, parent), CI_BY, named="lead", parent=parent)
    s.pairs.append((a.source, key))
    s.flush()
    print(r)


def forge_state(pr_url):
    """open, merged or closed for a pull request URL, or None when the forge cannot say (gh is stubbed in tests)."""
    r = subprocess.run(["gh", "pr", "view", pr_url, "--json", "state", "--jq", ".state"], capture_output=True, text=True)
    return r.stdout.strip().lower() or None if r.returncode == 0 else None


def cmd_compare(a):
    os.environ["JG_HOME"] = os.path.realpath(a.home)
    s = Session()
    st, out = s.st, []
    seen = set()
    for hf in sorted(os.listdir(os.path.join(s.home, "data", "jg-merge-on-green"))) if os.path.isdir(os.path.join(s.home, "data", "jg-merge-on-green")) else []:
        if not hf.endswith(".head"):
            continue
        task = hf[:-5]
        rec = record(s.home, task)
        if not rec.get("pr") or release_of(rec):
            continue
        ticket, _ = itemdb.task_ref(s.home, task)
        key = K.key("merge", s.hid, ticket=ticket, pr=pr_number(rec["pr"]))
        seen.add(key)
        state = forge_state(rec["pr"])
        done = st.one("SELECT 1 FROM item WHERE key=? AND state='done'", (key,))
        if state == "merged" and not done:
            out.append("%s merge today=merged store=%s" % (key, "open" if st.item(key) else "none"))
        elif state == "open" and not st.item(key):
            out.append("%s merge today=open store=%s" % (key, "done" if done else "none"))
    for key, in st.con.execute("SELECT key FROM item WHERE kind='merge' AND state='open' AND home=?", (s.hid,)).fetchall():
        if key not in seen:
            out.append("%s merge today=none store=open" % key)
    print("\n".join(out))
    sys.exit(1 if out else 0)


def main(argv):
    p = argparse.ArgumentParser(prog="merge.py", description=__doc__.split("\n")[0])
    sp = p.add_subparsers(dest="cmd", required=True)
    for name, fn, pos in (("step", cmd_step, ("home_id", "task", "pull_request", "head")),
                          ("merged", cmd_merged, ("home_id", "task", "pull_request", "commit")),
                          ("red", cmd_red, ("home_id", "ticket", "run_id"))):
        c = sp.add_parser(name)
        for x in pos:
            c.add_argument(x)
        c.add_argument("--source", required=True)
        c.set_defaults(fn=fn)
    c = sp.add_parser("compare")
    c.add_argument("home")
    c.set_defaults(fn=cmd_compare)
    a = p.parse_args(argv)
    try:
        a.fn(a)
    except itemdb.Unbound as e:
        die("refused: %s" % e, 2)


if __name__ == "__main__":
    main(sys.argv[1:])
