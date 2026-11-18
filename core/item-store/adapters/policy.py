#!/usr/bin/env python3
"""policy.py: the owner's project policy, written and read through the item store (docs/item-store.md).

  --import [--registry <home>] [--table <rules.tsv>]
      The one cut-over run: version 1 of every project in <home>/data/projects.md (default: JG_HOME), at one stamp, stamped
      `owner:registry`, source import:projects.md:<project>. It prints the table it wrote (and, with --table, one check line
      per project) and saves the table to <main home>/state/item-store/cut-over-policy.tsv, which logs/owner-registry reads.
      Version 1 reproduces today's delivery rules exactly: +yolo is loose, local-trunk is standard, everything else is tight.
  --check <registry home> --table <rules.tsv>
      Reads each version-1 row back through bin/jg-project-mode.sh --raw and the rules table; prints `<project> ok` or the
      difference, one line per project; exit 1 on any difference.
  --from-message --channel chat|board --message-id <id> --project <p> --level tight|standard|loose [--mode <m>]
      His own message that names the change writes version n+1 directly (stamped owner:<channel>).
  --propose --project <p> --level <l> [--mode <m>]
      Main's proposal: opens question:policy/<p>#v<n> (home `policy`) with the full text and the picks yes|no. His
      `owner.py answer ... --pick yes` writes version n (owner.py reads the text back through this module's `apply`).
  --row <project>
      Prints the newest version as one line; exit 1 when the project has no row.
A project registered after the cut-over gets its version 1 only through --from-message or --propose.
Exit: 0 done, 1 refused or a difference, 2 usage."""
import argparse, os, re, subprocess, sys

HERE = os.path.dirname(os.path.realpath(__file__))
ITEM = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(ITEM))
sys.path.insert(0, ITEM)
import itemdb  # noqa: E402
import store as S  # noqa: E402

LEVELS = ("tight", "standard", "loose")
MODES = ("no-mistakes", "direct-PR", "local", "local-only", "local-trunk", "no-mistakes-prod-only")
# what the registry resolver prints for a registry word: (mode, does +yolo survive)
RESOLVE = {"no-mistakes": ("direct-PR", True), "no-mistakes-prod-only": ("no-mistakes-prod-only", True), "direct-PR": ("direct-PR", True),
           "local": ("local", True), "local-only": ("local-only", True), "local-trunk": ("local-trunk", True)}
PLACE = re.compile(r"mode=(\S+) level=(\S+) merge=(\S+) land=(\S+) release=(\S+) lanes=(\d+) trunk=([^\s;]+)")


def die(msg, code=1):
    print(msg, file=sys.stderr if code == 2 else sys.stdout)
    sys.exit(code)


def jg_home():
    h = os.environ.get("JG_HOME")
    if not h or not os.path.isdir(h):
        die("refused: JG_HOME must name this home's directory", 2)
    return os.path.realpath(h)


def registry(home):
    """(project, registry word, +yolo registered) for each line of <home>/data/projects.md; the word is read as
    bin/jg-project-mode.sh reads it: the bracket tokens in any order, +yolo and the key=value ones set aside, the rest is the
    mode; a line with no brackets is the legacy default (no-mistakes, yolo off)."""
    out = []
    try:
        lines = open(os.path.join(home, "data", "projects.md"), encoding="utf-8").read().splitlines()
    except OSError:
        return out
    for ln in lines:
        if not ln.startswith("- "):
            continue
        rest = ln[2:]
        cut = [i for i in (rest.find(" ["), rest.find(" - ")) if i > 0]
        if not cut:
            continue
        i = min(cut)
        name = rest[:i]
        word, yolo = "no-mistakes", False
        if rest[i:].startswith(" ["):
            toks = rest[i + 2:].split("]", 1)[0].split()
            yolo = "+yolo" in toks
            left = [t for t in toks if t != "+yolo" and not re.match(r"(branch|forge|mcp)=", t)]
            word = left[0] if left else "no-mistakes"
        out.append((name, word, yolo))
    return out


def formula(word, yolo):
    """The import formula: (mode, level). +yolo is loose; local-trunk is standard (lands on a PASS by itself, goes live on
    his word); anything else is tight (his one word merges or lands, and carries the release)."""
    mode, keeps = RESOLVE.get(word, ("direct-PR", False))
    on = yolo and keeps
    return mode, "loose" if on else "standard" if mode == "local-trunk" else "tight"


def lanes_of(main, project):
    """Today's lane cap: config/project-capacity when it declares one, else the policy's widest (no cap today)."""
    try:
        for ln in open(os.path.join(main, "config", "project-capacity"), encoding="utf-8"):
            f = ln.split()
            if len(f) >= 2 and not ln.lstrip().startswith("#") and " ".join(f[:-1]) == project and f[-1].isdigit():
                return max(1, min(16, int(f[-1])))
    except OSError:
        pass
    return 16


def trunk_of(main, project):
    try:
        t = open(os.path.join(main, "state", "trunk-branch-" + project), encoding="utf-8").read().strip()
        if t:
            return t
    except OSError:
        pass
    return "main"


def resolver(reg, project):
    env = dict(os.environ, JG_HOME=reg, JG_DATA_OVERRIDE=os.path.join(reg, "data"))
    env.pop("JG_ROOT_OVERRIDE", None)
    return subprocess.run([os.path.join(ROOT, "bin", "jg-project-mode.sh"), "--raw", project], env=env,
                          capture_output=True, text=True).stdout.split()


def table_of(path):
    t = {}
    for ln in open(path, encoding="utf-8"):
        if ln.startswith("#") or ln.startswith("word\t") or not ln.strip():
            continue
        w, y, mg, ld, rl = ln.rstrip("\n").split("\t")[:5]
        t[(w, y)] = (mg, ld, rl)
    return t


def row_of(st, project, version=None):
    """(project, version, level, mode, merge, land, release, lanes, trunk) of one version, or the newest."""
    cols = "project, version, level, mode, merge, land, release, lanes, trunk"
    if version:
        return st.con.execute("SELECT %s FROM policy WHERE project=? AND version=?" % cols, (project, version)).fetchone()
    return st.con.execute("SELECT %s FROM v_policy WHERE project=?" % cols, (project,)).fetchone()


def check_lines(st, reg, tbl):
    """One (project, ok, reference-format line, difference) per registered project, read back from version 1."""
    rules, out = table_of(tbl), []
    for name, word, yolo in registry(reg):
        r = row_of(st, name, 1)
        got = resolver(reg, name)
        want = rules.get((word, "on" if yolo else "off"))
        if not r:
            out.append((name, False, "check %-12s no policy row" % name, "no policy row"))
            continue
        _, _, level, mode, merge, land, release, _, _ = r
        on = "on" if level == "loose" else "off"
        ok_read, ok_rule = got == [mode, on], want == (merge, land, release)
        bad = ("" if ok_read else " (read-back: resolver %s, row %s %s)" % (" ".join(got) or "nothing", mode, on)) + \
              ("" if ok_rule else " (rules: table %s, row %s)" % ("/".join(want) if want else "no row", "/".join((merge, land, release))))
        ref = "check %-12s resolver: %-26s rules table: %-24s policy: %-8s %s" % (
            name, " ".join(got), "/".join(want) if want else "no row", level, "ok" if ok_read and ok_rule else "MISMATCH" + bad)
        out.append((name, ok_read and ok_rule, ref, "MISMATCH" + bad))
    return out


def cmd_import(a):
    home = jg_home()
    main = itemdb.main_home(home)
    if itemdb.home_id(home) != "main":
        die("refused: the cut-over import runs in the main home only")
    reg = os.path.realpath(a.registry or home)
    st = itemdb.open_db(home, "owner:registry")
    if st.one("SELECT 1 FROM policy WHERE set_by='owner:registry'"):
        die("refused: the cut-over import already ran; a later version comes only from his own message")
    projects = registry(reg)
    if not projects:
        die("refused: %s lists no project" % os.path.join(reg, "data", "projects.md"))
    at = itemdb.stamp(st)
    try:
        for name, word, yolo in projects:
            mode, level = formula(word, yolo)
            st.set_policy(at, name, level, "owner:registry", "import:projects.md:" + name, mode=mode, lanes=lanes_of(main, name),
                          trunk=trunk_of(main, name))
    except S.Refused as e:
        die("refused: %s" % e)
    head = "project\tmode\tyolo\tlevel\tmerge\tland\trelease"
    lines = [head]
    for name, _, _ in projects:
        _, _, level, mode, merge, land, release, _, _ = row_of(st, name, 1)
        lines.append("\t".join((name, mode, "on" if level == "loose" else "off", level, merge, land, release)))
    os.makedirs(itemdb.store_dir(home), exist_ok=True)
    with open(os.path.join(itemdb.store_dir(home), "cut-over-policy.tsv"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    if a.table:
        for _, _, ref, _ in check_lines(st, reg, a.table):
            print(ref)


def cmd_check(a):
    home = jg_home()
    if not a.table:
        die("policy --check: missing --table", 2)
    st = itemdb.open_db(home, "owner:registry")
    bad = 0
    for name, ok, _, diff in check_lines(st, os.path.realpath(a.check), a.table):
        print("%s %s" % (name, "ok" if ok else diff))
        bad += not ok
    sys.exit(1 if bad else 0)


def next_text(st, project, level, mode, home):
    """The full text of version n of a project's policy (what a question carries and `apply` reads back)."""
    cur = row_of(st, project)
    v = (cur[1] if cur else 0) + 1
    if mode is None:
        mode = cur[3] if cur else (resolver(home, project) or ["direct-PR"])[0]
    if mode not in MODES:
        die("refused: mode %s is not one of %s" % (mode, ", ".join(MODES)))
    lv = S.LEVELS[level]
    lanes, trunk = (cur[7], cur[8]) if cur else (lanes_of(itemdb.main_home(home), project), trunk_of(itemdb.main_home(home), project))
    return v, ("policy %s v%d: mode=%s level=%s merge=%s land=%s release=%s lanes=%d trunk=%s" %
               (project, v, mode, level, lv["merge"], lv["land"], lv["release"], lanes, trunk))


def log_pair(home, channel, source, key):
    """His message's own log (logs/owner-<channel> reads it): the pair the stamp check will look for."""
    d = itemdb.store_dir(home)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "owner-%s.log" % channel), "a", encoding="utf-8") as fh:
        fh.write("%s\t%s\n" % (source, key))


def apply(st, at, text, channel, source):
    """Write the version a policy question's text names, as his answer (stamped owner:<channel> by the caller's store)."""
    m = re.match(r"policy (\S+) v(\d+): ", text)
    p = PLACE.search(text)
    if not m or not p:
        raise S.Refused("policy: %r is not a policy question's text" % text[:60])
    mode, level, merge, land, release, lanes, trunk = p.groups()
    return st.set_policy(at, m.group(1), level, st.me, source, mode=mode, lanes=int(lanes), trunk=trunk, merge=merge, land=land, release=release)


def cmd_from_message(a):
    home = jg_home()
    st = itemdb.open_db(home, "owner:" + a.channel)
    v, text = next_text(st, a.project, a.level, a.mode, home)
    at = itemdb.stamp(st)
    source = "%s:%s" % (a.channel, a.message_id)
    if st.one("SELECT 1 FROM policy WHERE source=?", (source,)):
        print("again")
        return
    log_pair(home, a.channel, source, "policy:" + a.project)
    try:
        print("version %d" % apply(st, at, text, a.channel, source))
    except S.Refused as e:
        die("refused: %s" % e)


def cmd_propose(a):
    home = jg_home()
    if itemdb.home_id(home) != "main":
        die("refused: only Main proposes a policy change")
    st = itemdb.open_db(home, "main")
    v, text = next_text(st, a.project, a.level, a.mode, home)
    at = itemdb.stamp(st)
    key = "question:policy/%s#v%d" % (a.project, v)
    r = itemdb.or_intake(st, at, "propose:%s@v%d" % (a.project, v), "main", a.project, st.open, at, key, "question", "policy", a.project,
                         text + "; yes writes it, no keeps the policy as it is", st.me, options="yes|no")
    print(r)


def cmd_row(a):
    home = jg_home()
    st = itemdb.open_db(home, "owner:registry")
    r = row_of(st, a.row)
    if not r:
        sys.exit(1)
    _, _, level, mode, merge, land, release, lanes, trunk = r
    print("mode=%s level=%s merge=%s land=%s release=%s lanes=%d trunk=%s" % (mode, level, merge, land, release, lanes, trunk))


def main(argv):
    p = argparse.ArgumentParser(prog="policy.py", description=__doc__.split("\n")[0])
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--import", dest="imp", action="store_true")
    g.add_argument("--check")
    g.add_argument("--from-message", action="store_true")
    g.add_argument("--propose", action="store_true")
    g.add_argument("--row")
    p.add_argument("--registry")
    p.add_argument("--table")
    p.add_argument("--channel", choices=("chat", "board"))
    p.add_argument("--message-id")
    p.add_argument("--project")
    p.add_argument("--level", choices=LEVELS)
    p.add_argument("--mode")
    a = p.parse_args(argv)
    try:
        if a.imp:
            cmd_import(a)
        elif a.check:
            cmd_check(a)
        elif a.row:
            cmd_row(a)
        else:
            need = ("channel", "message_id", "project", "level") if a.from_message else ("project", "level")
            miss = [n for n in need if getattr(a, n) is None]
            if miss:
                die("policy.py: missing --%s" % miss[0].replace("_", "-"), 2)
            (cmd_from_message if a.from_message else cmd_propose)(a)
    except itemdb.Unbound as e:
        die("refused: %s" % e, 2)


if __name__ == "__main__":
    main(sys.argv[1:])
