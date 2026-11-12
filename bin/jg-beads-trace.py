#!/usr/bin/env python3
"""jg-beads-trace.py - the adapter verb that writes a ticket's provenance: the event first, then the moment on the row.

Usage: BEADS_DIR=<store> jg-beads-write.py trace record <ticket or task> <kind> <ref-kind> <ref> --source <source> [--at <RFC3339 or epoch seconds>] [--payload <JSON>] [--once]

--once writes nothing, with exit 0, when the row already holds the moment and nothing undid it (live_at is undone by a later pinned_back_at).
record takes a ticket id or a task name (the row's metadata.task), so it still finds the ticket after the lane was torn down. It writes the
provenance event first and the row second, because the row write is the signal a reader polls and the event alone leaves no trace on the row.
The row gets the moment `<source>` stands for, as an RFC3339 string in UTC equal to the event's time. A landing also sets `commit` to the ref.
It only adds: a time earlier than the one already on the row is refused, and no key is ever removed. A repeat of the same event adds nothing.
The row is written with --metadata (one JSON object that keeps every other key), so an all-digit SHA stays a string.
"""
import datetime
import json
import sys
import time

sys.dont_write_bytecode = True
view = __import__("jg-beads-view")
moment = __import__("jg-beads-moment")

# source -> (the row's moment key, whether the ref is the landed commit, the row's list that grows by the ref). One line per producer;
# S12 and S27 added theirs: a pull-request merge sets no commit, the URL in external_ref is its pointer. A key may be a dict by event kind (the ready step records commit and resume under one source); None writes no moment.
SOURCES = {
    "jg-trunk-land": ("landed_at", True, None),
    "jg-trunk-revert": ("reverted_at", False, None),
    "jg-trunk-live": ("live_at", False, None),
    "jg-trunk-pin-back": ("pinned_back_at", False, None),
    "jg-trunk-release": ("released_at", False, None),
    "jg-merge": ("landed_at", False, None),
    "jg-merge-local": ("landed_at", True, None),
    "jg-spawn": (None, False, None),
    "jg-done": ({"commit": "ready_at", "resume": "resumed_at"}, False, None),
    "jg-receipt": (None, False, None),
    "jg-evidence": (None, False, "evidence"),
}
# The moment that undoes another: live_at is current only while no later pinned_back_at is on the row.
UNDONE_BY = {"live_at": "pinned_back_at"}


def record(args):
    found, ids = view.flags(args, ("--source", "--at", "--payload"), ("--once",))
    if len(ids) != 4 or found.get("--source") not in SOURCES:
        view.refuse("usage: trace record <ticket> <kind> <ref-kind> <ref> --source <%s> [--at <RFC3339>] [--payload <JSON>] [--once]" % "|".join(SOURCES))
    started, (ticket, kind, ref_kind, ref) = time.monotonic(), ids
    source, at = found["--source"], found.get("--at")
    when = moment.utc(datetime.datetime.fromtimestamp(int(at), datetime.timezone.utc).isoformat() if at and at.isdigit() else at)
    key, lands, grows = SOURCES[source]
    key = key.get(kind) if isinstance(key, dict) else key
    row = moment.fetch(ticket)
    meta = dict(row.get("metadata") or {})
    held = str(meta.get(key) or "") if key else ""
    if found.get("--once") and held and held > str(meta.get(UNDONE_BY.get(key)) or ""):
        moment.done(started, "skip: %s %s is already %s" % (row["id"], key, held))
        return
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
    if key:
        meta[key] = when
    if lands:
        meta["commit"] = str(ref)
    if grows:  # a comma-joined list that only grows
        have = view.split(meta.get(grows))
        meta[grows] = ",".join(have + [ref] if ref not in have else have)
    if key or lands or grows:
        moment.bd("update", row["id"], "--metadata", json.dumps(meta, sort_keys=True))
    moment.done(started, "ok: %s %s = %s" % (row["id"], key or kind, when))


def main(args):
    if not args or args[0] != "record":
        view.refuse("usage: trace record <ticket> <kind> <ref-kind> <ref> --source <source>")
    record(args[1:])
