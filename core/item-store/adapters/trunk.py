#!/usr/bin/env python3
"""The trunk adapter (stamp adapter:trunk): landings, release pushes and his release word, recorded in the item store beside
today's records. bin/jg-trunk.sh and core/trunk-landing/trunk-landing.sh call it (each call guarded by config/item-store and
ended `|| true`); today's word check decides, and every disagreement is one intake item on Main.

  landed <home id> <ticket> <head> <landed commit> --source land:<task>@<commit>
      Closes land:<home id>/<ticket>@<head> done `trunk:<landed commit>` (the lander may re-cut the commit: the item names
      the commit that stands on the trunk, so `jg-item landed <ticket>` answers it once the stamp check has passed).
  pushed <project> <release pull request> <head> --source push:<head>
      Store.release_push: the first push opens the release step (or his question), a later one is a note on it. The store
      writes the push's moves as the tick, so they need no line in this adapter's log.
  released <project> <release pull request> <head> --project-dir <dir> --source merged:<pull request>@<head>
      Store.release_out; then, when the project is the homes' own repository (the same origin URL as the main home's),
      one update:<home id>@<head> for each home core/item-store/homes.sh prints.
  covered <project> <release pull request>       prints Store.covered_head, or nothing
  word <project> <release pull request> <head> --word-id <epoch>@<commit>
      His recorded release word as his yes (owner.py answer --channel trunk-word). The id's commit must be <head>: a yes
      covers the head his word names, never one above it.
  agree <project> <release pull request> <head>
      After today's check passed and the push was recorded: when the store's yes does not cover <head> (covered is <head>
      or has it under it), opens intake:main/release-disagree-<project>@<pull request>. It never refuses anything.
  daily                                          each open release pull request with no open release item or question
                                                 opens intake:main/release-<project>@<pull request> on Main
  compare <project>                              data/trunk-landings.tsv, trunk-releases.tsv and trunk-words.tsv against the
                                                 store: one line per difference, exit 1 when any

Each write's pair (source, item key) is appended to <main home>/state/item-store/trunk-written.log, which logs/adapter-trunk
prints for the stamp check. Every write goes through itemdb.or_intake: a refused write is one intake item on Main."""
import argparse, hashlib, os, re, subprocess, sys

HERE = os.path.dirname(os.path.realpath(__file__))
ITEM = os.path.dirname(HERE)
sys.path.insert(0, ITEM)
import itemdb   # noqa: E402
import keys     # noqa: E402

STAMP = "adapter:trunk"
LOGNAME = "trunk-written.log"


def jg_home():
    h = os.environ.get("JG_HOME")
    if not h:
        sys.exit("trunk.py: JG_HOME is not set")
    return h


class Writer:
    """One call's session: the store as adapter:trunk, the home, and the pairs written (logged before the write)."""

    def __init__(self):
        self.home = jg_home()
        self.main = itemdb.main_home(self.home)
        self.hid = itemdb.home_id(self.home)
        self.st = itemdb.open_db(self.home, STAMP)

    def log(self, source, key):
        os.makedirs(itemdb.store_dir(self.home), exist_ok=True)
        with open(os.path.join(itemdb.store_dir(self.home), LOGNAME), "a", encoding="utf-8") as fh:
            fh.write("%s\t%s\n" % (source, key))

    def put(self, home, subject, source, key, call, *args, **kw):
        """One write through or_intake; its pair is logged first (and the refusal's intake item's pair after it)."""
        if key:
            self.log(source, key)
        at = itemdb.stamp(self.st)
        r = itemdb.or_intake(self.st, at, source, home, subject, call, at, *args, **kw)
        if r == "intake":
            self.log("refused:" + source, "intake:%s/refused-%s" % (home, hashlib.sha256(source.encode()).hexdigest()[:12]))
        return r

    def intake(self, key, source, subject, owes):
        return self.put("main", subject, source, key, self.st.open, key, "intake", "main", subject, owes, self.st.me)


def data_dir(main):
    return os.environ.get("JG_DATA_OVERRIDE") or os.path.join(main, "data")


def tsv(path):
    try:
        return [ln.split("\t") for ln in open(path, encoding="utf-8").read().splitlines() if ln.strip()]
    except OSError:
        return []


def pr_number(ref):
    return ref.rstrip("/").rsplit("/", 1)[-1]


def git(d, *a):
    try:
        r = subprocess.run(["git", "-C", d] + list(a), capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def cmd_landed(a):
    w = Writer()
    key = keys.key("land", a.home_id, ticket=a.ticket, head=a.head)
    print(w.put(a.home_id, a.ticket, a.source, key, w.st.close, key, "done", "trunk:" + a.commit, w.st.me))


def cmd_pushed(a):
    w = Writer()
    print(w.put(w.hid, "%s@%s" % (a.project, a.pr), a.source, None, w.st.release_push, a.project, a.pr, a.head))


def homes(main):
    try:
        out = subprocess.run([os.path.join(ITEM, "homes.sh"), main], capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return [ln.split("\t")[0] for ln in out.splitlines() if "\t" in ln]


def cmd_released(a):
    w = Writer()
    step = "release:%s@%s" % (a.project, a.pr)
    r = w.put(w.hid, "%s@%s" % (a.project, a.pr), a.source, step, w.st.release_out, a.project, a.pr, a.head)
    print(r)
    theirs, ours = git(a.project_dir, "remote", "get-url", "origin"), git(w.main, "remote", "get-url", "origin")
    if not theirs or theirs != ours:
        return
    for h in homes(w.main):
        k = keys.key("update", h, version=a.head)
        w.put(h, a.head, a.source, k, w.st.open, k, "update", h, a.head, "run release " + a.head, w.st.me)


def cmd_covered(a):
    c = Writer().st.covered_head(a.project, a.pr)
    if c:
        print(c)


def machine(st, project):
    """A project whose policy lets the machine release: no question is asked, so there is no yes to record or to cover."""
    return st.one("SELECT release FROM v_policy WHERE project=?", (project,)) == "machine"


def cmd_word(a):
    if a.word_id.partition("@")[2] != a.head:
        print("refused: the word's commit is not %s: his yes covers the head his word names" % a.head)
        sys.exit(2)
    if not Writer().st.item("question:release:%s@%s" % (a.project, a.pr)):
        print("nothing asked")       # a machine release, or his yes is already recorded: there is no open question to answer
        return
    env = dict(os.environ, JG_HOME=jg_home())
    r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "owner.py"), "answer", "--channel", "trunk-word", "--message-id", a.word_id,
                        "--key", "question:release:%s@%s" % (a.project, a.pr), "--pick", "yes"], env=env, capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    sys.exit(r.returncode)


def covers(main, project, covered, head):
    if not covered:
        return False
    return covered == head or subprocess.run(["git", "-C", os.path.join(main, "projects", project), "merge-base", "--is-ancestor", head, covered],
                                             capture_output=True).returncode == 0


def cmd_agree(a):
    w = Writer()
    cov = w.st.covered_head(a.project, a.pr)
    if machine(w.st, a.project) or covers(w.main, a.project, cov, a.head):
        print("agree")
        return
    key = "intake:main/release-disagree-%s@%s" % (a.project, a.pr)
    print(w.intake(key, "agree:%s@%s" % (a.project, a.head), "%s@%s" % (a.project, a.pr),
                   ("today's word check let %s go into release pull request %s of %s; the store's yes covers %s: place the difference" %
                    (a.head, a.pr, a.project, cov or "nothing"))[:300]))


def pr_open(project_dir, url):
    m = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/pull/(\d+)", url)
    if not m:
        return False
    try:
        r = subprocess.run(["gh-axi", "pr", "view", m.group(2), "--repo", m.group(1)], cwd=project_dir, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return False
    return any(ln.lower().split()[:2] == ["state:", "open"] for ln in r.stdout.splitlines())


def cmd_daily(a):
    w = Writer()
    last = {}
    for f in tsv(os.path.join(data_dir(w.main), "trunk-releases.tsv")):
        if len(f) >= 6:
            last[f[0]] = f[5]
    n = 0
    for project, url in sorted(last.items()):
        pr = pr_number(url)
        step = "release:%s@%s" % (project, pr)
        if not pr_open(os.path.join(w.main, "projects", project), url):
            continue
        if w.st.item(step) or w.st.item("question:" + step):
            continue
        key = "intake:main/release-%s@%s" % (project, pr)
        r = w.intake(key, "daily:release-%s@%s" % (project, pr), "%s@%s" % (project, pr),
                     "release pull request %s of %s is open and nothing in the store asks or releases it: place it" % (pr, project))
        n += r == "open"
    print(n)


def cmd_compare(a):
    w = Writer()
    d, st, out = data_dir(w.main), w.st, []
    seen = set()
    for f in tsv(os.path.join(d, "trunk-landings.tsv")):
        if len(f) >= 3 and f[1] == a.project and (f[0], f[2]) not in seen:
            seen.add((f[0], f[2]))
            if not st.one("SELECT 1 FROM item WHERE kind='land' AND state='done' AND outcome=?", ("trunk:" + f[2],)):
                out.append("landing %s %s: no closed land item names it" % (f[0], f[2]))
    for f in tsv(os.path.join(d, "trunk-releases.tsv")):
        if len(f) >= 6 and f[0] == a.project:
            step = "release:%s@%s" % (a.project, pr_number(f[5]))
            if not st.one("SELECT 1 FROM move WHERE key IN (?, ?) AND source=?", (step, "question:" + step, "push:" + f[2])):
                out.append("release %s %s: no release item records the push" % (f[2], f[5]))
    for f in tsv(os.path.join(d, "trunk-words.tsv")):
        if len(f) >= 5 and f[0] == a.project and f[1] == "release" and not machine(st, a.project):
            if not st.one("SELECT 1 FROM item WHERE kind='question' AND closed_by='owner:trunk-word' AND outcome=?",
                          ("owner:trunk-word:%s@%s pick=yes" % (f[3], f[2]),)):
                out.append("word %s@%s: no yes move records it" % (f[3], f[2]))
    for ln in out:
        print(ln)
    sys.exit(1 if out else 0)


def main(argv):
    p = argparse.ArgumentParser(prog="trunk.py", description=__doc__.split("\n")[0])
    sp = p.add_subparsers(dest="cmd", required=True)

    def add(name, fn, *pos, **opts):
        s = sp.add_parser(name)
        for x in pos:
            s.add_argument(x)
        for o, req in opts.items():
            s.add_argument("--" + o.replace("_", "-"), required=req)
        s.set_defaults(fn=fn)
    add("landed", cmd_landed, "home_id", "ticket", "head", "commit", source=True)
    add("pushed", cmd_pushed, "project", "pr", "head", source=True)
    add("released", cmd_released, "project", "pr", "head", project_dir=True, source=True)
    add("covered", cmd_covered, "project", "pr")
    add("word", cmd_word, "project", "pr", "head", word_id=True)
    add("agree", cmd_agree, "project", "pr", "head")
    add("daily", cmd_daily)
    add("compare", cmd_compare, "project")
    a = p.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main(sys.argv[1:])
