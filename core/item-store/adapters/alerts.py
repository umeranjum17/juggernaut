#!/usr/bin/env python3
"""The alerts adapter (stamp adapter:alerts): every alert bin/jg-alert.sh raises is also one store item keyed by its cause.

  alerts.py raise <alert> <subject> [--security-source <s>] --source <id>
  alerts.py resolve <key> --proof <p> --source <id>          (<key> is jg-alert's <alert>--<subject>)
  alerts.py compare <home>                                    (the daily measure against <home>/state/alerts/)
  alerts.py import <home>                                     (the cut-over: one item for each alert open today in <home>, source
                                                               import:<home id>/<key>, and the close of each item whose alert is
                                                               absent or resolved today; a second run changes nothing and says so)

A subject that has a task record (<home>/state/<subject>.meta) is a lane's task id: the item's subject is its ticket and
its first holder is the lead (Main, in the main home), so the lane's done close drops it with the rest of the lane's
alerts (Y5). Any other subject stays as given and Main holds it. A host-wide security cause (--security-source) is one
`security:fleet/<alert>` item, never one per home. The plumbing alerts about delivery and escalation raise no item:
the late item itself climbs. Every write goes through itemdb.or_intake, so a refused write is listed on Main's board.
The alert records under state/alerts/ stay authoritative; this adapter only mirrors them. Stdlib only."""
import argparse, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
import itemdb   # noqa: E402
import store as S   # noqa: E402

BY = "adapter:alerts"
PLUMBING = {"undelivered", "slow-delivery", "stuck-wait", "escalation-stuck"}


def home_of():
    h = os.environ.get("JG_HOME")
    if not h or not os.path.isdir(h):
        sys.exit("alerts: JG_HOME must name this home's directory")
    return os.path.realpath(h)


def subject_of(home, subject):
    """(item subject, named holder): a lane's task id maps to its ticket and the lead; anything else stays, with Main."""
    if os.path.exists(os.path.join(home, "state", subject + ".meta")):
        return itemdb.task_ref(home, subject)[0], "lead"
    return subject, "main"


def item_key(hid, alert, subject):
    return S.Store.alert_key(alert, hid, subject)


def mirror(st, home, hid, alert, subject, security_source, source):
    """The one item of one alert (raise and import share it): a security cause is one fleet item, any other is keyed by its cause."""
    subj, named = subject_of(home, subject)
    at = itemdb.stamp(st)
    if security_source:
        return itemdb.or_intake(st, at, source, hid, subj, st.open, at, "security:fleet/%s" % alert, "security", "main", alert,
                                "%s: raised in home %s (source %s)" % (alert, hid, security_source), st.me)
    return itemdb.or_intake(st, at, source, hid, subj, st.open, at, item_key(hid, alert, subj), "alert", hid, subj,
                            "%s on %s" % (alert, subject), st.me, named=named)


def cmd_raise(a):
    if a.alert in PLUMBING:
        return
    home = home_of()
    hid = itemdb.home_id(home)
    print(mirror(itemdb.open_db(home, BY), home, hid, a.alert, a.subject, a.security_source, a.source))


def cmd_resolve(a):
    alert, sep, subject = a.key.partition("--")
    if not sep or not alert or not subject or alert in PLUMBING:
        return
    home = home_of()
    hid = itemdb.home_id(home)
    st = itemdb.open_db(home, BY)
    subj, _ = subject_of(home, subject)
    key = item_key(hid, alert, subj)
    if not st.item(key):            # a plumbing alert, one the lane's done close already dropped, or one never mirrored
        return
    at = itemdb.stamp(st)
    print(itemdb.or_intake(st, at, a.source, hid, subj, st.close, at, key, "done", "gone:" + a.proof, st.me))


def records(home):
    """(alert, subject, security source) of each open alert record: every state but resolved is live (jg-alert.sh list)."""
    d = os.path.join(home, "state", "alerts")
    out = []
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if not name.endswith(".rec"):
            continue
        f = {}
        for ln in open(os.path.join(d, name), encoding="utf-8", errors="replace"):
            k, _, v = ln.rstrip("\n").partition("=")
            f[k] = v
        if f.get("state") != "resolved" and f.get("alert") and f.get("subject") and f["alert"] not in PLUMBING:
            out.append((f["alert"], f["subject"], f.get("security_source", "")))
    return out


def open_items(st, hid):
    """(key, subject) of each open alert item this home holds, its own tick's plumbing excluded (the compare's `have`)."""
    return list(st.con.execute("SELECT key, subject FROM item WHERE state='open' AND kind='alert' AND home=? AND opened_by<>'tick'", (hid,)))


def wanted(home, hid):
    return {"security:fleet/%s" % alert if sec else item_key(hid, alert, subject_of(home, subject)[0])
            for alert, subject, sec in records(home)}


def cmd_compare(a):
    home = os.path.realpath(a.home)
    hid = itemdb.home_id(home)
    st = itemdb.open_db(home, BY)
    want = wanted(home, hid)
    have = {k for k, _ in open_items(st, hid)}
    have |= {k for k in want if k.startswith("security:fleet/") and st.item(k)}
    diffs = ["%s missing-item today=open store=absent" % k for k in sorted(want - have)]
    diffs += ["%s missing-record today=absent store=open" % k for k in sorted(have - want)]
    if diffs:
        print("\n".join(diffs))
    sys.exit(1 if diffs else 0)


def cmd_import(a):
    """Open the item of each alert that is open today and has none; the alerts raised before the adapter was wired were never mirrored.
    Close the item of each alert that is absent or resolved today: its clearing never reached the store."""
    home = os.path.realpath(a.home)
    hid = itemdb.home_id(home)
    st = itemdb.open_db(home, BY)
    opened = there = closed = 0
    for alert, subject, sec in records(home):
        key = "security:fleet/%s" % alert if sec else item_key(hid, alert, subject_of(home, subject)[0])
        if st.item(key):
            there += 1
            continue
        mirror(st, home, hid, alert, subject, sec, "import:%s/%s--%s@%d" % (hid, alert, subject, time.time_ns()))
        opened += 1
    want = wanted(home, hid)
    for key, subj in open_items(st, hid):
        if key in want:
            continue
        at = itemdb.stamp(st)
        itemdb.or_intake(st, at, "import:%s/gone:%s@%d" % (hid, key, time.time_ns()), hid, subj, st.close, at, key, "done", "gone:import-absent-today", st.me)
        closed += 1
    tail = ", closed %d" % closed if closed else ""
    print("alerts import %s: opened %d, already open %d%s" % (hid, opened, there, tail) if opened or closed else
          "alerts import %s: nothing to import (%d already open)" % (hid, there))


def main(argv):
    p = argparse.ArgumentParser(prog="alerts.py", description=__doc__.split("\n")[0])
    sp = p.add_subparsers(dest="cmd", required=True)
    r = sp.add_parser("raise")
    r.add_argument("alert"); r.add_argument("subject")
    r.add_argument("--security-source", default=None); r.add_argument("--source", required=True)
    r.set_defaults(fn=cmd_raise)
    c = sp.add_parser("resolve")
    c.add_argument("key"); c.add_argument("--proof", required=True); c.add_argument("--source", required=True)
    c.set_defaults(fn=cmd_resolve)
    m = sp.add_parser("compare")
    m.add_argument("home")
    m.set_defaults(fn=cmd_compare)
    i = sp.add_parser("import")
    i.add_argument("home")
    i.set_defaults(fn=cmd_import)
    a = p.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main(sys.argv[1:])
