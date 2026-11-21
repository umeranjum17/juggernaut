#!/usr/bin/env python3
"""jg-backlog-tree.py - one tree from an ask to the work of every home that holds a part of it.

Usage: jg-backlog.sh tree --homes

Reads each home that `jg-backlog.sh homes --json` lists and prints every ticket that has children, as `<home>:<id>  [status]  title`, with its
children indented below it. A child is a row whose parent is the ticket, or a row the ticket tracks: a part of an ask that moved to another home
reads as the ticket's child through the edges of the move (its `parent` = external:<home>:<id>, the ask's tracks edge to it). The two edges are
one relation, so a moved child is printed once. A home whose store cannot be read is named on stderr and left out. It writes nothing.
"""
import json
import os
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))


def key(home, ident):
    """A ticket's name across homes: an external edge already carries `<home>:<id>`."""
    return ident[len("external:"):] if ident.startswith("external:") else "%s:%s" % (home, ident)


def load(home, directory):
    run = subprocess.run([sys.executable, "-I", os.path.join(HERE, "..", "core", "item-store", "adapters", "bd_compat.py"), "list", "--all", "--limit", "0", "--json"],
                         env={**os.environ, "JG_HOME": directory},
                         capture_output=True, text=True, check=False)
    if run.returncode:
        sys.stderr.write("jg-backlog tree: %s left out, its store cannot be read: %s\n" % (home, (run.stderr or run.stdout).strip().splitlines()[-1:] or "no answer"))
        return []
    return [row for row in json.loads(run.stdout or "[]") or [] if row.get("issue_type") != "gate"]


def main(args):
    if args != ["--homes"]:
        sys.stderr.write("usage: jg-backlog.sh tree --homes\n")
        return 2
    homes = json.loads(subprocess.run([os.path.join(HERE, "jg-backlog-homes.sh"), "--json"], capture_output=True, text=True, check=True).stdout)
    nodes, children = {}, {}
    for one in homes:
        for row in load(one["home"], one["dir"]) if one.get("dir") else []:
            nodes[key(one["home"], row["id"])] = row
            for edge in row.get("dependencies") or []:
                if edge.get("type") == "tracks":  # this row is carried out by the target
                    children.setdefault(key(one["home"], row["id"]), set()).add(key(one["home"], edge["depends_on_id"]))
            if row.get("parent"):
                children.setdefault(key(one["home"], row["parent"]), set()).add(key(one["home"], row["id"]))
    below = {child for kids in children.values() for child in kids}

    def show(name, depth):
        row = nodes.get(name)
        print("%s%s  [%s]  %s" % ("  " * depth, name, row["status"] if row else "not here", row["title"] if row else ""))
        for child in sorted(children.get(name, ())):
            show(child, depth + 1)

    for name in sorted(set(children) - below):
        show(name, 0)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
