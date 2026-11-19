#!/usr/bin/env python3
"""daily_files.py: the daily check of big flat files (Y9: a growing flat file stopped a lead).

  daily_files.py <home>
      Lists each file over 1 MB (1048576 bytes) under <home>/state/ as one item for Main: intake:<home id>/big-files@<date> (the
      date is the host's day), through itemdb.or_intake, its text naming each path (relative to the home) and size. With no such
      file it writes nothing. Run twice on one day it writes once. A symbolic link is never followed.
Exit: 0 done, 2 usage."""
import os, sys, time

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import itemdb  # noqa: E402

LIMIT = 1024 * 1024
BY = "adapter:daily-files"


def big_files(home):
    """[(path relative to the home, size)] of each file over the limit under <home>/state/, largest first."""
    found = []
    for root, _, names in os.walk(os.path.join(home, "state")):
        for n in names:
            p = os.path.join(root, n)
            try:
                if not os.path.islink(p) and os.path.getsize(p) > LIMIT:
                    found.append((os.path.relpath(p, home), os.path.getsize(p)))
            except OSError:
                continue            # gone between the listing and the read
    return sorted(found, key=lambda f: (-f[1], f[0]))


def main(argv):
    if len(argv) != 1 or not os.path.isdir(argv[0]):
        print("usage: daily_files.py <home>", file=sys.stderr)
        sys.exit(2)
    home = os.path.realpath(argv[0])
    found = big_files(home)
    if not found:
        return
    try:
        hid = itemdb.home_id(home)
        st = itemdb.open_db(home, BY)
    except itemdb.Unbound as e:
        print("refused: %s" % e, file=sys.stderr)
        sys.exit(2)
    at = itemdb.stamp(st)
    day = time.strftime("%Y-%m-%d", time.localtime(at))
    key = "intake:%s/big-files@%s" % (hid, day)
    owes = "%d file(s) over 1 MB under state/: %s" % (len(found), "; ".join("%s %.1f MB" % (p, n / LIMIT) for p, n in found))
    print(itemdb.or_intake(st, at, "big-files:%s@%s" % (hid, day), hid, "big-files", st.open, at, key, "intake", hid, "big-files",
                           owes[:300], st.me))


if __name__ == "__main__":
    main(sys.argv[1:])
