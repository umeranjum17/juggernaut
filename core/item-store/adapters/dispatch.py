#!/usr/bin/env python3
"""The dispatch adapter (stamp adapter:dispatch): an approved ticket is owed until a lane starts it. The approval records
(state/dispatch-approved/<ticket>) and the spawn records stay authoritative until the switch; `compare` measures how far
the store agrees with them.

  dispatch.py approve <home id> <ticket> --source <approval record id>
      opens dispatch:<home id>/<ticket> (held by the lead, 24 hours); a second approval of the same ticket is a note
  dispatch.py spawned <home id> <task id> --source spawn:<task id>
      closes the ticket's open dispatch item (the newest, and any older one) done `lane:<task id>` and, in the same write,
      opens work:<home id>/<task id> (lane worker:<home id>/<task id>, the project of the task record), so the lane's work is
      open when the lane adapter reads its first line. When the store refuses the work (no policy row, the project's lane
      limit) the whole write is refused and the refusal is one intake item on Main; the dispatch item stays open
  dispatch.py requeue <home id> <ticket> <n> --words <text> --source requeue:<ticket>#<n>
      opens dispatch:<home id>/<ticket>#<n> carrying the new words. It opens no steer, so no steer clock runs while it waits
  dispatch.py next <home id> <ticket>
      prints the number of the ticket's open requeue (a second call for the same wait is a note on it, so a spawn that is
      deferred on every beat opens one item), else the next free number (1 when it has none)
  dispatch.py prior-work <task id>
      prints `open` or `closed` and exits 0 when the store holds work for the task that an earlier lane opened (open: that lane
      was cleaned before its done line; closed: a reopen), exit 1 when it holds none
  dispatch.py compare <home>
      each approval record not yet spawned against an open dispatch, and each spawned lane against a closed one: one line per
      difference, exit 1 when any

Every write goes through itemdb.or_intake, so a refused write is listed on Main's board, never lost. Exit: 0 done (also a
refused write: it is then an intake item), 1 a difference (compare), 2 usage or a store that cannot answer."""
import argparse, os, re, sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import itemdb   # noqa: E402
import keys as K   # noqa: E402

BY = "adapter:dispatch"
APPROVED = "dispatch-approved"


def open_dispatches(st, hid, ticket):
    """The open dispatch items of a ticket: the newest requeue first, the plain one last."""
    base = K.key("dispatch", hid, ticket=ticket)
    keys = [k for (k,) in st.con.execute("SELECT key FROM item WHERE kind='dispatch' AND state='open' AND subject=? AND home=?", (ticket, hid))
            if re.fullmatch(re.escape(base) + r"(#\d+)?", k)]
    return sorted(keys, key=lambda k: int(k.rsplit("#", 1)[1]) if "#" in k else 0, reverse=True)


def requeue_numbers(st, hid, ticket):
    base = K.key("dispatch", hid, ticket=ticket)
    out = []
    for (k,) in st.con.execute("SELECT DISTINCT key FROM item WHERE kind='dispatch' AND subject=? AND home=?", (ticket, hid)):
        m = re.fullmatch(re.escape(base) + r"#(\d+)", k)
        if m:
            out.append(int(m.group(1)))
    return out


def cmd_approve(a):
    st = itemdb.open_db(a.home, BY)
    hid = itemdb.home_id(os.path.realpath(a.home))
    if a.home_id != hid:
        return refuse("home id %s is not this home's (%s)" % (a.home_id, hid))
    at = itemdb.stamp(st)
    key = K.key("dispatch", hid, ticket=a.ticket)
    itemdb.or_intake(st, at, a.source, hid, a.ticket, st.open, at, key, "dispatch", hid, a.ticket,
                     "start %s: approved to start" % a.ticket, st.me)
    return 0


def cmd_spawned(a):
    st = itemdb.open_db(a.home, BY)
    hid = itemdb.home_id(os.path.realpath(a.home))
    task = a.task
    if st.seen(a.source):
        return 0
    ticket, project = itemdb.task_ref(os.path.realpath(a.home), task)
    at = itemdb.stamp(st)
    open_keys = open_dispatches(st, hid, ticket)
    work = K.key("work", hid, task=task)
    step = dict(key=work, kind="work", home=hid, subject=ticket, owes="the lane's task", lane="worker:%s/%s" % (hid, task), project=project,
                parent=open_keys[0] if open_keys else None)
    if not open_keys:       # a lane the store never saw approved: only its work opens
        itemdb.or_intake(st, at, a.source, hid, ticket, st.open, at, work, "work", hid, ticket, step["owes"], st.me,
                         lane=step["lane"], project=project)
        return 0
    first, rest = open_keys[0], open_keys[1:]
    r = itemdb.or_intake(st, at, a.source, hid, ticket, st.close, at, first, "done", "lane:" + task, st.me, then=[step])
    if r == "done":         # the work is open: any older dispatch of the same ticket is the same cause, closed beside it
        for k in rest:
            itemdb.or_intake(st, at, a.source, hid, ticket, st.close, at, k, "done", "lane:" + task, st.me)
    return 0


def cmd_requeue(a):
    st = itemdb.open_db(a.home, BY)
    hid = itemdb.home_id(os.path.realpath(a.home))
    at = itemdb.stamp(st)
    key = K.key("dispatch", hid, ticket=a.ticket, n=a.n)
    itemdb.or_intake(st, at, a.source, hid, a.ticket, st.open, at, key, "dispatch", hid, a.ticket,
                     ("start %s again: %s" % (a.ticket, a.words))[:300], st.me)
    return 0


def cmd_next(a):
    st = itemdb.open_db(a.home, BY)
    hid = itemdb.home_id(os.path.realpath(a.home))
    waiting = [int(k.rsplit("#", 1)[1]) for k in open_dispatches(st, hid, a.ticket) if "#" in k]
    print(max(waiting) if waiting else max(requeue_numbers(st, hid, a.ticket) or [0]) + 1)
    return 0


def cmd_prior_work(a):
    st = itemdb.open_db(a.home, BY)
    got = st.one("SELECT state FROM item WHERE key=? ORDER BY gen DESC LIMIT 1", (K.key("work", itemdb.home_id(os.path.realpath(a.home)), task=a.task),))
    if got is None:
        return 1
    print("open" if got == "open" else "closed")
    return 0


def cmd_compare(a):
    home = os.path.realpath(a.home)
    st = itemdb.open_db(home, BY)
    hid = itemdb.home_id(home)
    state = os.path.join(home, "state")
    lines = []
    try:
        tickets = sorted(f for f in os.listdir(os.path.join(state, APPROVED)) if os.path.isfile(os.path.join(state, APPROVED, f)))
    except OSError:
        tickets = []
    spawned_tickets = set()
    for f in os.listdir(state):
        if f.endswith(".meta"):
            spawned_tickets.add(itemdb.task_ref(home, f[:-5])[0])
    for ticket in tickets:
        key = K.key("dispatch", hid, ticket=ticket)
        got = st.one("SELECT state FROM item WHERE key=? ORDER BY gen DESC LIMIT 1", (key,))
        spawned = ticket in spawned_tickets
        if not spawned and got != "open":
            lines.append("approved %s: no open %s in the store" % (ticket, key))
        elif spawned and got == "open":
            lines.append("spawned %s: %s is still open in the store" % (ticket, key))
        elif spawned and got is None:
            lines.append("spawned %s: the store never opened %s" % (ticket, key))
    for ln in lines:
        print(ln)
    return 1 if lines else 0


def refuse(msg):
    print("dispatch.py: " + msg, file=sys.stderr)
    return 2


def main(argv):
    p = argparse.ArgumentParser(prog="dispatch.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("approve"); s.add_argument("home_id"); s.add_argument("ticket"); s.add_argument("--source", required=True)
    s.set_defaults(f=cmd_approve)
    s = sub.add_parser("spawned"); s.add_argument("home_id"); s.add_argument("task"); s.add_argument("--source", required=True)
    s.set_defaults(f=cmd_spawned)
    s = sub.add_parser("requeue"); s.add_argument("home_id"); s.add_argument("ticket"); s.add_argument("n")
    s.add_argument("--words", required=True); s.add_argument("--source", required=True)
    s.set_defaults(f=cmd_requeue)
    s = sub.add_parser("next"); s.add_argument("home_id"); s.add_argument("ticket"); s.set_defaults(f=cmd_next)
    s = sub.add_parser("prior-work"); s.add_argument("task"); s.set_defaults(f=cmd_prior_work)
    s = sub.add_parser("compare"); s.add_argument("home"); s.set_defaults(f=cmd_compare)
    a = p.parse_args(argv)
    if a.cmd != "compare":
        a.home = os.environ.get("JG_HOME", "")
    if not a.home:
        return refuse("JG_HOME is not set")
    try:
        return a.f(a)
    except itemdb.Unbound as e:
        return refuse(str(e))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
