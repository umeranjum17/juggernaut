#!/usr/bin/env python3
"""jg-beads-links.py - turn the linked-to: and parent: lines of a row's body into Beads edges.

bin/jg-beads-write.py and bin/jg-beads-migrate.py import it, so a line becomes an edge when it is written or migrated.
No reader parses a body: bin/jg-beads-view.py reads the edges alone, and the lines stay in the body as the row's text.
A parent: line is a parent-child edge. A linked-to: line is a blocks edge when one side is a decision, the work waiting
on the decision, and a related edge between siblings. A word that names no row stays text until that row is filed.
"""
import re
import sys

sys.dont_write_bytecode = True
view = __import__("jg-beads-view")

LINE = re.compile(r"^[ \t]*(linked-to|parent):(.*)$", re.M)
WORD = re.compile(r"[A-Za-z0-9._-]+\Z")


def named(body):
    """The (kind, word) pairs a body's lines name; a word that is no id links nothing, and upkeep is a bucket."""
    return [(kind, word) for kind, tail in LINE.findall(body or "") for word in re.split(r"[,;\s]+", tail)
            if WORD.match(word) and word.lower() != "upkeep"]


def decision(row):
    """A held row or a design row: the two kinds bin/jg-captain-hold.sh can read as an open decision."""
    return row.get("status") in view.HELD or "[design-ux]" in row.get("title", "")


def edge(row, other, kind):
    """The rows a line joins, dependent first, and the edge type."""
    if kind == "parent":
        return row, other, "parent-child"
    if decision(other):
        return row, other, "blocks"
    return (other, row, "blocks") if decision(row) else (row, other, "related")


def joined(one, two):
    """The type of the edge between two rows in either direction, or None."""
    return next((d.get("type") for a, b in ((one, two), (two, one)) for d in a.get("dependencies") or []
                 if d["depends_on_id"] == b["id"]), None)


def join(one, two, kind):
    one.setdefault("dependencies", []).append({"issue_id": one["id"], "depends_on_id": two["id"], "type": kind})


def lines(items, scope=None):
    """Yield (row, other, kind, word) for each line, other None when no row answers; scope keeps the lines touching one row."""
    names = {scope, *view.legacy(items[scope])} if scope else None
    for row in list(items.values()):
        for kind, word in named(row.get("description")):
            if not names or row["id"] == scope or word in names:
                other = view.named(items.values(), word)
                if other is not row:
                    yield row, other, kind, word


def pending(items, scope=None):
    """The lines with no edge yet, read as the edges land: a word a row recorded as unresolved is settled."""
    for row, other, kind, word in lines(items, scope):
        if other is None:
            if word not in ((row.get("metadata") or {}).get("linked_to") or []):
                yield row, None, kind, word
        elif not joined(row, other):
            yield row, other, kind, word
