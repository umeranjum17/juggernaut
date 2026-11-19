#!/usr/bin/env python3
"""owner.py: the owner's words and calls as items (docs/item-store.md). Every write goes through itemdb.or_intake, so a
write the store refuses is listed as one intake item on Main and never lost; the subcommand prints the store's answer
(open, note, done, again) or `intake`. Exit: 0 written or listed, 1 a difference (compare) or a refusal, 2 usage.

  tell --channel chat|board --message-id <id> --subject <ticket or -> --text <text>
      Opens tell:<home id>/<message id> (holder Main), stamped owner:<channel>, source <channel>:<message id>. Only the chat
      adapter's sent record closes it (turn_end.py).
  answer --channel chat|board|trunk-word|rules --message-id <id> --key <question key> --pick <pick>
      Closes the question done with proof `owner:<channel>:<message id> pick=<pick>`. A pick he was not offered is refused by
      the store. His yes on a step question (land, merge or release) opens that step in the same write; his yes on a policy
      question writes that policy version. trunk-word is his recorded release word (the trunk adapter calls it); rules is
      his standing release word, recorded in the release pull request's task record as merge_rule=. Any other channel exits 2.
  compare <home>
      Today's records against the store, one line per difference `<record> <what> today=<v> store=<v>`; exit 1 on any.
  import-holds <home>
      The one-time cut-over step: each legacy hold of that home (its channel status file's open `captain hold <ticket>:` keys,
      and each active captain hold) becomes one open question, written quietly as that home's writer. Main's home also opens the
      rule item of each standing proof bypass already granted (config/proof-bypass), as bypass.py grant would. An absent hold
      file (no backlog store) reads as no holds, not as unreadable. Run twice, it writes nothing.

His channels' own logs are <store dir>/owner-chat.log and owner-board.log: the adapter appends `<source>\\t<item key>` before
its write, and logs/owner-chat and logs/owner-board hand them to the tick's stamp check."""
import argparse, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
ITEM = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(ITEM))
sys.path.insert(0, ITEM)
import itemdb  # noqa: E402
import store as S  # noqa: E402

CHANNELS = ("chat", "board", "trunk-word", "rules")
STEP = re.compile(r"question:(land|merge):(?P<home>[^/]+)/(?P<ticket>[^@]+)@(?P<ref>.+)$")
RELEASE = re.compile(r"question:release:(?P<project>[^@]+)@(?P<ref>.+)$")
HOLD = re.compile(r"captain hold ([A-Za-z0-9._-]+):\s*(.*)", re.S)
TAG = re.compile(r"\[(\w[\w-]*)=([^\]]*)\]")


def die(msg, code=1):
    print(msg, file=sys.stderr if code == 2 else sys.stdout)
    sys.exit(code)


def jg_home():
    h = os.environ.get("JG_HOME")
    if not h or not os.path.isdir(h):
        die("refused: JG_HOME must name this home's directory", 2)
    return os.path.realpath(h)


def derive_by(home):
    hid = itemdb.home_id(home)
    return "main" if hid == "main" else "lead:" + hid


def write(st, at, source, home, subject, call, *args, **kw):
    """The one write path: a refusal becomes one intake item on Main. The intake item is stamped adapter:intake, not by his
    channel, because the stamp check must not read a filing as his word."""
    return itemdb.or_intake(st.as_("adapter:intake"), at, source, home, subject, call, *args, **kw)


def log_pair(home, channel, source, key):
    """His message's own log (logs/owner-<channel>): the pair the stamp check looks for, written before the store move."""
    if channel not in ("chat", "board"):
        return
    d = itemdb.store_dir(home)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "owner-%s.log" % channel), "a", encoding="utf-8") as fh:
        fh.write("%s\t%s\n" % (source, key))


def cmd_tell(a):
    home = jg_home()
    hid = itemdb.home_id(home)
    st = itemdb.open_db(home, "owner:" + a.channel)
    at = itemdb.stamp(st)
    key = "tell:%s/%s" % (hid, a.message_id)
    source = "%s:%s" % (a.channel, a.message_id)
    log_pair(home, a.channel, source, key)
    subject = a.subject if a.subject and a.subject != "-" else "owner"
    print(write(st, at, source, hid, subject, st.open, at, key, "tell", hid, subject, a.text, st.me))


def step_of(st, key):
    """The step his yes on a step question lets through, as a `then` entry (store.close), or None for a plain question."""
    m = STEP.fullmatch(key)
    r = RELEASE.fullmatch(key)
    pj = st.one("SELECT project FROM item WHERE key=? AND state='open'", (key,))
    if m:
        kind, ticket, ref = m.group(1), m.group("ticket"), m.group("ref")
        what = {"land": "land %s at %s", "merge": "merge pull request %s of %s"}[kind]
        owes = (what % (ticket, ref)) if kind == "land" else (what % (ref, ticket))
        return dict(key=key[len("question:"):], kind=kind, home=m.group("home"), subject=ticket, owes=owes + ": his yes is recorded", project=pj)
    if r:
        pr = "%s@%s" % (r.group("project"), r.group("ref"))
        return dict(key=key[len("question:"):], kind="release", home=r.group("project"), subject=pr, project=r.group("project"),
                    owes="release pull request %s of %s: his yes is recorded" % (r.group("ref"), r.group("project")))
    return None


def cmd_answer(a):
    home = jg_home()
    hid = itemdb.home_id(home)
    st = itemdb.open_db(home, "owner:" + a.channel)
    at = itemdb.stamp(st)
    source = "%s:%s" % (a.channel, a.message_id)
    log_pair(home, a.channel, source, a.key)
    then = []
    policy = None
    if a.pick == "yes" and st.item(a.key):
        step = step_of(st, a.key)
        if step:
            then.append(step)
        if a.key.startswith("question:policy/"):
            policy = st.one("SELECT why FROM move WHERE key=? AND verb='open' ORDER BY seq DESC LIMIT 1", (a.key,))
    proof = "owner:%s:%s pick=%s" % (a.channel, a.message_id, a.pick)
    item = st.item(a.key)
    subject = item["subject"] if item else a.key
    r = write(st, at, source, hid, subject, st.close, at, a.key, "done", proof, st.me, then=then)
    if r == "done" and policy:
        import policy as P
        pj = re.match(r"policy (\S+) v", policy).group(1)
        log_pair(home, a.channel, source, "policy:" + pj)
        try:
            P.apply(st, at, policy, a.channel, source)
        except S.Refused as e:
            r = write(st, at, source + "#policy", hid, subject, lambda **kw: (_ for _ in ()).throw(e))
    print(r)


# ------------------------------------------------------------------ compare, and the one-time import

def backlog_holds(home):
    """(ticket, gate id, the day it was set, its question) of each active captain hold: this home's open owner questions (bin/jg-backlog.sh questions)."""
    env = dict(os.environ, JG_HOME=home)
    for k in ("JG_STATE_OVERRIDE", "JG_DATA_OVERRIDE", "JG_CONFIG_OVERRIDE"):
        env.pop(k, None)
    r = subprocess.run([os.path.join(ROOT, "bin", "jg-backlog.sh"), "questions", "--json"], env=env, capture_output=True, text=True)
    if r.returncode != 0:
        return [] if "needs its store" in r.stderr else None      # a home with no hold file holds nothing; any other refusal is unreadable
    try:
        rows = json.loads(r.stdout or "[]")
    except ValueError:
        return None
    return [(x.get("ticket"), x.get("id"), str(x.get("day") or "0"), x.get("question") or x.get("title") or "")
            for x in rows if x.get("ticket")]


def inbox_notes(main):
    """Ids of the notes still waiting (not in handled/)."""
    ids = []
    for d in (os.path.join(main, "state", "inbox"), os.path.join(main, "data", "inbox")):
        try:
            ids += [n[:-5] for n in os.listdir(d) if n.endswith(".note")]
        except OSError:
            pass
    return sorted(set(ids))


def standing_bypasses(main, now):
    """Each standing proof bypass of config/proof-bypass that has not ended: its fields (id, scope, target, word, ..., end, standing)."""
    try:
        lines = open(os.path.join(main, "config", "proof-bypass"), encoding="utf-8").read().splitlines()
    except OSError:
        return []
    out = []
    for ln in lines:
        f = ln.split("\t")
        if len(f) >= 7 and f[6] == "standing" and not (f[5] != "-" and f[5].isdigit() and int(f[5]) <= now):
            out.append(f)
    return out


def cmd_compare(a):
    import time
    home = os.path.realpath(a.home)
    os.environ["JG_HOME"] = home
    hid = itemdb.home_id(home)
    main = itemdb.main_home(home)
    st = itemdb.open_db(home, derive_by(home))
    out = []
    holds = backlog_holds(home)
    qs = {}     # ticket -> an open question key of this home on it
    for key, subj in st.con.execute("SELECT key, subject FROM item WHERE kind='question' AND state='open' AND home=? AND key NOT LIKE 'question:release:%'", (hid,)):
        qs.setdefault(subj, key)
    if holds is None:
        out.append("%s holds unreadable today=? store=%d" % (hid, len(qs)))
    else:
        tickets = {t for t, _, _, _ in holds}
        for t in sorted(tickets - set(qs)):
            out.append("%s question today=held store=none" % t)
        for t in sorted(set(qs) - tickets):
            out.append("%s hold today=none store=%s" % (qs[t], "open"))
    if hid == "main":
        for nid in inbox_notes(main):
            if not st.item("tell:%s/%s" % (hid, nid)):
                out.append("%s tell today=waiting store=none" % nid)
        for f in standing_bypasses(main, int(time.time())):
            if not st.item("rule:%s/%s" % (f[1], f[2])):
                out.append("%s rule today=standing store=none" % f[0])
    print("\n".join(out))
    sys.exit(1 if out else 0)


def channel_holds(home, hid):
    """(key, ticket, text) of each legacy hold key of a Squad Lead's channel status file with no later `resolved [key=<k>]`
    (the fold is replay6.py's pre_channel)."""
    path = os.path.join(itemdb.main_home(home), "state", hid + ".status")
    open_, order = {}, []
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return []
    for ln in lines:
        head, sep, body = ln.partition("]:")
        body = body.strip() if sep else ""
        key = dict(TAG.findall(head)).get("key", "")
        m = HOLD.match(body)
        if not m or not key:
            continue
        if ln.startswith(("blocked", "needs-decision")):
            if key not in open_:
                order.append(key)
            open_[key] = (m.group(1), body)
        elif ln.startswith("resolved"):
            open_.pop(key, None)
    return [(k, open_[k][0], open_[k][1]) for k in order if k in open_]


def cmd_import_holds(a):
    home = os.path.realpath(a.home)
    os.environ["JG_HOME"] = home
    hid = itemdb.home_id(home)
    st = itemdb.open_db(home, derive_by(home))
    at = itemdb.stamp(st)
    todo = []
    if hid != "main":
        todo += [("hold:%s/%s" % (hid, k), t, text) for k, t, text in channel_holds(home, hid)]
    holds = backlog_holds(home) or []
    todo += [("hold:%s@%s" % (t, since), t, text or "held for the owner") for t, _, since, text in holds]
    lines = len(todo)
    opened = 0
    for source, ticket, text in todo:
        key = "question:%s/%s" % (hid, ticket)
        r = write(st, at, source, hid, ticket, st.open, at, key, "question", hid, ticket, text, st.me, quiet=True, options="yes|no")
        opened += r == "open"
    rules = 0
    if hid == "main":                  # a bypass granted before the store was on has no rule item: the same write bypass.py grant makes
        import time
        for f in standing_bypasses(home, int(time.time())):
            r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "bypass.py"), "grant", "--id", f[0], "--scope", f[1], "--target", f[2],
                                "--word", f[3], "--until", f[5]], env=dict(os.environ, JG_HOME=home), capture_output=True, text=True)
            lines += 1
            if r.returncode != 0:
                die("import-holds %s: bypass %s refused: %s" % (hid, f[0], (r.stdout + r.stderr).strip()))
            rules += r.stdout.strip() == "open"
    print("import-holds %s: %d records, %d questions opened%s" % (hid, lines, opened, ", %d rules opened" % rules if rules else ""))


def main(argv):
    p = argparse.ArgumentParser(prog="owner.py", description=__doc__.split("\n")[0])
    sp = p.add_subparsers(dest="cmd", required=True)
    t = sp.add_parser("tell")
    t.add_argument("--channel", choices=("chat", "board"), required=True)
    for n in ("message-id", "subject", "text"):
        t.add_argument("--" + n, required=True)
    t.set_defaults(fn=cmd_tell)
    s = sp.add_parser("answer")
    s.add_argument("--channel", choices=CHANNELS, required=True)
    for n in ("message-id", "key", "pick"):
        s.add_argument("--" + n, required=True)
    s.set_defaults(fn=cmd_answer)
    c = sp.add_parser("compare")
    c.add_argument("home")
    c.set_defaults(fn=cmd_compare)
    i = sp.add_parser("import-holds")
    i.add_argument("home")
    i.set_defaults(fn=cmd_import_holds)
    a = p.parse_args(argv)
    if a.cmd not in ("compare", "import-holds"):
        jg_home()
    try:
        a.fn(a)
    except itemdb.Unbound as e:
        die("refused: %s" % e, 2)


if __name__ == "__main__":
    main(sys.argv[1:])
