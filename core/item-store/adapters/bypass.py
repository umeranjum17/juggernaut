#!/usr/bin/env python3
"""bypass.py: a proof bypass as a `rule` item (bin/jg-proof-bypass.sh calls it after it writes config/proof-bypass, which stays
authoritative). Stamped owner:rules; the stamp check reads logs/owner-rules, which reads config/proof-bypass.

  grant --id <bypass id> --scope ticket|project|home --target <t or -> --word <id> --until <epoch or ->
      Opens rule:<scope>/<target> (holder outside), source = the word that holds his words, due at its end (the store caps a
      deadline at 30 days).
  end --id <bypass id> --word <id>
      His word ends it: closes the rule done, proof owner:rules:<word>, source bypass-end:<id>.
  drop --id <bypass id> --why expired|released
      The end time passed (`expired at <end>`) or its ticket was released (`released`): drops it, source bypass-end:<id>.
Every write goes through itemdb.or_intake. Prints the store's answer (open, note, done, dropped, again) or `intake`."""
import argparse, os, sys, time

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import itemdb  # noqa: E402

STAMP = "owner:rules"


def row(home, bid):
    cfg = os.environ.get("JG_CONFIG_OVERRIDE") or os.path.join(home, "config")
    try:
        for ln in open(os.path.join(cfg, "proof-bypass"), encoding="utf-8"):
            f = ln.rstrip("\n").split("\t")
            if f and f[0] == bid and len(f) >= 7:
                return f
    except OSError:
        pass
    return None


def main(argv):
    p = argparse.ArgumentParser(prog="bypass.py", description=__doc__.split("\n")[0])
    sp = p.add_subparsers(dest="cmd", required=True)
    g = sp.add_parser("grant")
    for n in ("id", "scope", "target", "word", "until"):
        g.add_argument("--" + n, required=True)
    e = sp.add_parser("end")
    e.add_argument("--id", required=True)
    e.add_argument("--word", required=True)
    d = sp.add_parser("drop")
    d.add_argument("--id", required=True)
    d.add_argument("--why", choices=("expired", "released"), required=True)
    a = p.parse_args(argv)
    home = os.environ.get("JG_HOME")
    if not home or not os.path.isdir(home):
        print("refused: JG_HOME must name this home's directory", file=sys.stderr)
        sys.exit(2)
    home = os.path.realpath(home)
    hid = itemdb.home_id(home)
    st = itemdb.open_db(home, STAMP)
    at = itemdb.stamp(st)
    w = st.as_("adapter:intake")
    if a.cmd == "grant":
        key = "rule:%s/%s" % (a.scope, a.target)
        subject = a.target if a.target != "-" else "home"
        due = max(1, int(a.until) - at) if a.until.isdigit() else None
        owes = "%s bypass %s: no proof runs for %s under %s%s" % (a.scope, a.id, "the home" if a.scope == "home" else a.target, a.word,
                                                                 "" if due is None else ", until " + time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(int(a.until))))
        r = itemdb.or_intake(w, at, a.word, hid, subject, st.open, at, key, "rule", hid, subject, owes, st.me, due=due)
    else:
        f = row(home, a.id)
        if not f:
            print("refused: no bypass %s in config/proof-bypass" % a.id, file=sys.stderr)
            sys.exit(1)
        key = "rule:%s/%s" % (f[1], f[2])
        subject = f[2] if f[2] != "-" else "home"
        source = "bypass-end:%s" % a.id
        if a.cmd == "end":
            r = itemdb.or_intake(w, at, source, hid, subject, st.close, at, key, "done", "owner:rules:%s" % a.word, st.me)
        else:
            end = time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(int(f[5]))) if f[5].isdigit() else "its end"
            r = itemdb.or_intake(w, at, source, hid, subject, st.close, at, key, "dropped", "expired at %s" % end if a.why == "expired" else "released", st.me)
    print(r)


if __name__ == "__main__":
    main(sys.argv[1:])
