#!/usr/bin/env python3
"""jg-beads-read.py - the read facts the ticket adapter needs from a Beads store, each proved in data/ta-j1-beads-facts/facts.md.

Usage: BEADS_DIR=<store>/.beads jg-beads-read.py rev <id>...
       BEADS_DIR=<store>/.beads jg-beads-read.py list [--after <id>] [--limit <1-500>]
       BEADS_DIR=<store>/.beads jg-beads-read.py show <id>...
       BEADS_DIR=<store>/.beads jg-beads-read.py history <id>

It only reads, and every call goes through bin/jg-beads.sh (JG_BEADS_SH names another wrapper), never bd or dolt directly.
rev prints one `<id><TAB><rev>` line per id; a missing id is refused. bd's own `revision` moves on every write to the row but not on a
label, dependency, parent or comment write, so rev is a 16-hex digest of that revision with the labels, the edges both ways and the
comment count. Compare it for equality only.
list walks the store with a cursor: one JSON object `{"rows": [...], "next": <id or null>}`, rows in id order, every row as `bd show --json`
gives it plus its `rev`. Closed rows and gates are left out, as `bd list` leaves them out, and `--after` takes the previous page's `next`.
show prints a JSON array of the rows as `bd show --json` gives them, each with its `rev`; a missing id exits 4, and a page of list that cannot be shown exits 5,
so a caller can tell a ticket that is not there, and a list that would be short, from a store that cannot be read.
history prints one line per commit that changed the row, newest first, `<commit><TAB><date><TAB><kind><TAB><changed columns>`, from
dolt_diff_issues: `bd history` lists every commit of the store, so it is not used.
"""
import hashlib
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
WRAPPER = os.environ.get("JG_BEADS_SH") or os.path.join(HERE, "jg-beads.sh")
IDENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
MAX_PAGE = 500
DEFAULT_PAGE = 50


def die(message, code=2):
    sys.stderr.write("jg-beads-read: %s\n" % message)
    sys.exit(code)


def ident(value):
    if not IDENT.match(value):
        die("not a ticket id: %r" % value)
    return value


def run(args, fail_code=None, absent=None):
    """The wrapper's stdout. A failure whose output contains `absent` is a ticket that is not there, so it returns "[]" for show to name."""
    done = subprocess.run([WRAPPER] + args, capture_output=True, text=True)
    if done.returncode != 0 and absent and absent in done.stdout + done.stderr:
        return "[]"
    if done.returncode != 0:
        die("%s failed (%d): %s" % (" ".join(args[:2]), done.returncode, done.stderr.strip() or done.stdout.strip()), fail_code or done.returncode)
    return done.stdout


def sql(query):
    """The rows of one SELECT as lists of cells, header dropped."""
    lines = [l for l in run(["dolt", "sql", "-q", query]).splitlines() if l.startswith("| ")]
    return [[c.strip() for c in l[2:-2].split(" | ")] for l in lines[1:]]


def rev_of(row):
    edges = lambda key: sorted((e["id"], e.get("dependency_type", "")) for e in row.get(key) or [])
    parts = [row.get("revision"), sorted(row.get("labels") or []), edges("dependencies"), edges("dependents"), row.get("comment_count", 0)]
    return hashlib.sha256(json.dumps(parts, sort_keys=True).encode()).hexdigest()[:16]


def show(ids, fail_code=None):
    rows = json.loads(run(["show"] + ids + ["--json", "--include-dependents", "--brief-deps"], fail_code, "not found") or "[]")
    found = {r["id"]: r for r in rows}
    missing = [i for i in ids if i not in found]
    if missing:
        die("no such ticket: %s" % ", ".join(missing), fail_code or 4)
    for r in rows:
        r["rev"] = rev_of(r)
    return rows


def cmd_rev(args):
    if not args:
        die("usage: rev <id>...")
    for r in show([ident(a) for a in args]):
        print("%s\t%s" % (r["id"], r["rev"]))


def cmd_list(args):
    after, limit = "", DEFAULT_PAGE
    while args:
        flag, args = args[0], args[1:]
        if flag not in ("--after", "--limit") or not args:
            die("usage: list [--after <id>] [--limit <1-%d>]" % MAX_PAGE)
        value, args = args[0], args[1:]
        if flag == "--after":
            after = ident(value) if value else ""
        elif value.isdigit() and 1 <= int(value) <= MAX_PAGE:
            limit = int(value)
        else:
            die("--limit must be a whole number from 1 to %d" % MAX_PAGE)
    ids = [r[0] for r in sql("select id from issues where status <> 'closed' and issue_type <> 'gate' and id > '%s' order by id limit %d" % (after, limit + 1))]
    more = len(ids) > limit
    ids = ids[:limit]
    rows = show(ids, 5) if ids else []
    rows.sort(key=lambda r: r["id"])
    print(json.dumps({"rows": rows, "next": ids[-1] if more else None}))


def cmd_show(args):
    if not args:
        die("usage: show <id>...")
    print(json.dumps(show([ident(a) for a in args])))


def cmd_history(args):
    if len(args) != 1:
        die("usage: history <id>")
    row = ident(args[0])
    cols = [c[0] for c in sql("select column_name from information_schema.columns where table_name = 'issues' order by ordinal_position")]
    cols = [c for c in cols if c != "id"]
    changed = ", ".join("not (from_%s <=> to_%s)" % (c, c) for c in cols)
    query = ("select coalesce(to_commit, from_commit), coalesce(to_commit_date, from_commit_date), diff_type, %s from dolt_diff_issues "
             "where to_id = '%s' or from_id = '%s' order by coalesce(to_commit_date, from_commit_date) desc, diff_type" % (changed, row, row))
    found = sql(query)
    if not found:
        die("no history for %s" % row, 1)
    for cell in found:
        names = [c for c, flag in zip(cols, cell[3:]) if flag == "1"]
        print("\t".join([cell[0], cell[1], cell[2], ",".join(names)]))


def main(argv):
    verbs = {"rev": cmd_rev, "list": cmd_list, "show": cmd_show, "history": cmd_history}
    if not argv or argv[0] not in verbs:
        die("usage: jg-beads-read.py <%s> ..." % "|".join(verbs))
    verbs[argv[0]](argv[1:])


if __name__ == "__main__":
    main(sys.argv[1:])
