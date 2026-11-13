#!/usr/bin/env python3
"""jg-beads-stage.py - the one rule that works out a ticket's stage, sub-state and health from its Beads row.

Usage: jg-beads-stage.py [<row.json>|-]     print "<stage>[.<sub>]<TAB><health>" for a row as `bd show --json` prints it
       import it as __import__("jg-beads-stage") and call stage(row), the function the terminal and the board both use.

The rule is section 6.3 of the state-machine plan, which extends the rule of jg-q1b3n section 6.5 from its five working words to the
seven stages of core/machines/ticket.states, the sub-states of delivering (core/machines/delivering.states) and the health words
(core/machines/ticket-health.states). Nothing is stored: a row has a status, started_at, an assignee and moments, each moment an
RFC3339 string in UTC in the row's metadata, so two moments compare as text, and the first matching line below wins.

A moment that is not set reads as the earliest. A try starts at the later of ready_at and resumed_at; proved_at, landing_at, gated_at,
returned_at, conflict_at and reverted_at count only while later than that start, so an earlier try's moments are not read for a new one.
A landing stands while landed_at is later than reverted_at, and the moments after it (live_at, release_opened_at, released_at) are read
whenever it stands, so a later done line does not undo a landing. A bypass (bypassed_at) counts as the proof moment of its try.
Health is red when the row's commit broke the line, lost when the row is in progress and its lease ran out before `now`, else ok;
slow and stuck need the alert table's limits and are not worked out here.
"""
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
MACHINES = os.path.join(ROOT, "core", "machines")
PR = re.compile(r"https://(github\.com/[^/\s]+/[^/\s]+/pull|[^/\s]+/[^/\s]+/[^/\s]+/pulls)/\d+\Z")
HELD = ("on_hold", "deferred", "blocked")


def words(name):
    """The state words of one closed enum file of core/machines, in file order."""
    with open(os.path.join(MACHINES, name + ".states")) as handle:
        return [line.split("\t")[0] for line in handle if line.strip() and not line.startswith("#")]


def proving_words():
    """The states of the proof run, which the proving table holds."""
    with open(os.path.join(MACHINES, "tables", "proving.tsv")) as handle:
        return [line.split("\t")[1] for line in handle if line.startswith("state\t")]


def later(a, b):
    """True when moment a is set and later than moment b; an unset moment is the earliest. RFC3339 UTC strings compare as text."""
    return bool(a) and a > (b or "")


def stage(row, proof="planned", now=""):
    """Return (stage, sub, health) for one row. `proof` is the stage of the done-done run for the commit (planned when none exists yet)
    and `now` is an RFC3339 UTC string for the lease check; with no `now` a lease is not judged."""
    meta = row.get("metadata") or {}

    def at(name):
        return str(meta.get(name) or "")

    status, started, closed = row.get("status") or "", row.get("started_at") or "", row.get("closed_at") or ""
    start = max(at("ready_at"), at("resumed_at"))

    def counts(name):
        return at(name) if later(at(name), start) else ""

    proved = max(counts("proved_at"), counts("bypassed_at"))
    landing, gated, returned, conflict, reverted = (counts(n) for n in ("landing_at", "gated_at", "returned_at", "conflict_at", "reverted_at"))
    landed, pinned, live = at("landed_at"), at("pinned_back_at"), at("live_at")
    stands = later(landed, at("reverted_at"))
    broke = later(reverted, landed) and (status != "closed" or later(reverted, closed))
    red = broke or (stands and later(pinned, landed) and later(pinned, live))
    lease = row.get("lease_expires_at") or ""
    health = "red" if red else "lost" if status == "in_progress" and now and lease and lease < now else "ok"
    released = bool(at("released_at")) and at("released_at") >= landed
    merged = not meta.get("commit") and bool(PR.match(row.get("external_ref") or ""))
    shipped = stands and (released or merged)
    if broke:
        return "building", "", health
    if status == "closed" and (not stands or shipped):
        return "closed", "", health
    if shipped:
        return "released", "", health
    if stands:
        if later(at("release_opened_at"), landed):
            return "delivering", "joining", health
        if later(live, landed) and later(live, pinned):
            return "delivering", "live", health
        return "delivering", "batched", health
    if later(returned, proved):
        return "building", "", health
    if later(conflict, landing):
        return "delivering", "resolving", health
    if proved and later(gated, landing):
        return "delivering", "gated", health
    if proved and landing:
        return "delivering", "rebased", health
    if proved:
        return "delivering", "queued", health
    if later(at("ready_at"), at("resumed_at")):
        return "proving", proof, health
    if status == "in_progress" or (status in HELD and started and row.get("assignee")):
        return "building", "", health
    return ("ready" if at("approved_at") else "intake"), "", health


def word(row, **kw):
    s, sub, health = stage(row, **kw)
    return (s + ("." + sub if sub else "")), health


def main(argv):
    src = argv[0] if argv else "-"
    row = json.load(sys.stdin if src == "-" else open(src))
    row = row[0] if isinstance(row, list) else row
    print("%s\t%s" % word(row))


if __name__ == "__main__":
    main(sys.argv[1:])
