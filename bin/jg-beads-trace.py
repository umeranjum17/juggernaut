#!/usr/bin/env python3
"""jg-beads-trace.py - the adapter verb that writes a ticket's provenance: the event first, then the moment on the row.

Usage: BEADS_DIR=<store> jg-beads-write.py trace record <ticket or task> <kind> <ref-kind> <ref> --source <source> [--at <RFC3339>] [--payload <JSON>]

record takes a ticket id or a task name (the row's metadata.task), so it still finds the ticket after the lane was torn down. It writes the
provenance event first and the row second, because the row write is the signal a reader polls and the event alone leaves no trace on the row.
The row gets the moment `<source>` stands for, as an RFC3339 string in UTC equal to the event's time. A landing also sets `commit` to the ref.
It only adds: a time earlier than the one already on the row is refused, and no key is ever removed. A repeat of the same event adds nothing.
The row is written with --metadata (one JSON object that keeps every other key), so an all-digit SHA stays a string.
"""
import json
import sys
import time

sys.dont_write_bytecode = True
view = __import__("jg-beads-view")
moment = __import__("jg-beads-moment")

# source -> (the row's moment key, whether the ref is the landed commit). One line per producer; S9, S12 and S27 add theirs.
SOURCES = {
    "jg-trunk-land": ("landed_at", True),
    "jg-trunk-revert": ("reverted_at", False),
}


def record(args):
    found, ids = view.flags(args, ("--source", "--at", "--payload"), ())
    if len(ids) != 4 or found.get("--source") not in SOURCES:
        view.refuse("usage: trace record <ticket> <kind> <ref-kind> <ref> --source <%s> [--at <RFC3339>] [--payload <JSON>]" % "|".join(SOURCES))
    started, (ticket, kind, ref_kind, ref) = time.monotonic(), ids
    source, when = found["--source"], moment.utc(found.get("--at"))
    key, lands = SOURCES[source]
    row = moment.fetch(ticket)
    meta = dict(row.get("metadata") or {})
    held = str(meta.get(key) or "")
    if held > when:
        view.refuse("%s is already %s, later than %s: a moment is never moved back" % (key, held, when), "Give a later --at", "MOMENT_BACK", 1)
    if found.get("--payload"):
        try:
            json.loads(found["--payload"])
        except ValueError:
            view.refuse("--payload must be JSON")
    # The event first, then the row: the row write is what a reader polls.
    event = ["provenance", "record", "--issue", row["id"], "--kind", kind, "--source", source, "--ref-kind", ref_kind, "--ref", ref, "--at", when]
    if found.get("--payload"):
        event += ["--payload", found["--payload"]]
    moment.bd(*event)
    meta[key] = when
    if lands:
        meta["commit"] = str(ref)
    moment.bd("update", row["id"], "--metadata", json.dumps(meta, sort_keys=True))
    moment.done(started, "ok: %s %s = %s" % (row["id"], key, when))


def main(args):
    if not args or args[0] != "record":
        view.refuse("usage: trace record <ticket> <kind> <ref-kind> <ref> --source <source>")
    record(args[1:])
