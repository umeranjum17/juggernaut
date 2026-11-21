#!/usr/bin/env python3
"""The supervision adapter (stamp adapter:supervision): Main-down is opened from a Squad Lead home.

  supervision.py check <this home> [--due <s>]

Main's own home cannot report its watcher stopping, so in the main home `check` does nothing. In a Squad Lead home it
reads the main home's watcher beat age (state/.last-watcher-beat, else state/.watch.lock/pid: bin/jg-wake-lib.sh's
jg_watcher_progress_age) and, over 900 s, opens `main-down:main/supervision` (a repeat is a note), source
`beat:<beat epoch>`. When the beat is fresh again it closes the item done `back:<beat epoch>`. This home's tick climbs it
to the owner, because every home runs the tick behind the store's lease. Each write's (source, key) pair is appended to
<main home>/state/item-store/supervision-written.log, which logs/adapter-supervision prints for the stamp check.
--due is for the test only: the item's first deadline in seconds, else the kind's 900. It prints nothing. Stdlib only."""
import argparse, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
import itemdb   # noqa: E402

BY = "adapter:supervision"
KEY = "main-down:main/supervision"
STALE = 900
LOG = "supervision-written.log"


def beat(main):
    """The epoch of the main home's last watcher beat (0 when neither file exists)."""
    for rel in (".last-watcher-beat", os.path.join(".watch.lock", "pid")):
        try:
            return int(os.stat(os.path.join(main, "state", rel)).st_mtime)
        except OSError:
            continue
    return 0


def cmd_check(a):
    home = os.path.realpath(a.home)
    main = itemdb.main_home(home)
    if main == home:
        return
    st = itemdb.open_db(home, BY)
    at = itemdb.stamp(st)
    epoch = beat(main)
    log = os.path.join(itemdb.store_dir(home), LOG)
    if at - epoch > STALE:
        src, r = "beat:%d" % epoch, None
        r = itemdb.or_intake(st, at, src, itemdb.home_id(home), "supervision", st.open, at, KEY, "main-down", "main", "supervision",
                             "Main's watcher has not beaten for %d s (last beat %d)" % (at - epoch, epoch), st.me, due=a.due)
    elif st.item(KEY):
        src = "back:%d" % epoch
        r = itemdb.or_intake(st, at, src, itemdb.home_id(home), "supervision", st.close, at, KEY, "done", src, st.me)
    else:
        return
    if r in ("open", "note", "done"):
        with open(log, "a", encoding="utf-8") as fh:
            fh.write("%s\t%s\n" % (src, KEY))


def main_(argv):
    p = argparse.ArgumentParser(prog="supervision.py", description=__doc__.split("\n")[0])
    sp = p.add_subparsers(dest="cmd", required=True)
    c = sp.add_parser("check")
    c.add_argument("home"); c.add_argument("--due", type=int, default=None)
    c.set_defaults(fn=cmd_check)
    a = p.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main_(sys.argv[1:])
