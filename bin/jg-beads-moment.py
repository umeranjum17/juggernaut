#!/usr/bin/env python3
"""jg-beads-moment.py - the adapter verbs that write a ticket's moments and wait, and read its stage.

Usage: BEADS_DIR=<store> jg-beads-write.py moment <ticket> <moment> [--at <RFC3339>] [--returned-to <stage>]
       BEADS_DIR=<store> jg-beads-write.py wait <ticket> <who> [<reason>] [--at <RFC3339>]
       BEADS_DIR=<store> jg-beads-write.py ticket-stage <ticket> [--proof <state of the proof run>]

moment writes one of six moments of the ticket machine: approved_at, proved_at, landing_at, gated_at, returned_at and release_opened_at.
Each is a provenance event first and then the row's metadata, in that order, because the row write is the signal a reader can poll and
the event alone leaves no trace on the row. The event carries the time given by --at (else now), so the id of the event is the same
when a writer fires twice. The metadata value is that time as an RFC3339 string in UTC, so two moments compare as text. A moment is
never removed: a time earlier than the one already on the row is refused, and a later one replaces it. returned_at also writes
returned_to (default building), the stage the ticket was given back to.
wait writes the three wait keys, wait (who owes the next move), wait_reason and wait_at, in one update; a wait ends by writing the
who `none`. The words are the closed lists of core/machines/ticket-wait.states and ticket-wait-reason.states. A wait adds no child row.
No stage word is stored, `bd set-state` is never called, and hold_kind is not written: the stage is worked out by bin/jg-beads-stage.py.
Every write prints one line with the seconds it took.
"""
import datetime
import json
import os
import subprocess
import sys
import time

sys.dont_write_bytecode = True
view = __import__("jg-beads-view")
rule = __import__("jg-beads-stage")

WRAPPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "jg-beads.sh")
# moment -> (provenance source, kind). bd has fixed kinds, so the source tells the moments apart.
MOMENTS = {
    "approved_at": ("jg-approve", "claim"),
    "proved_at": ("jg-prove", "used"),
    "landing_at": ("jg-trunk-landing", "land"),
    "gated_at": ("jg-trunk-gate", "land"),
    "returned_at": ("jg-trunk-return", "resume"),
    "release_opened_at": ("jg-trunk-release-open", "land"),
}


def bd(*args):
    run = subprocess.run([WRAPPER, *args], capture_output=True, text=True, check=False)
    if run.returncode:
        sys.stderr.write(run.stdout + run.stderr)
        sys.exit(run.returncode)
    return run.stdout


def utc(text):
    """Return an RFC3339 string in UTC to the second, from any RFC3339 time; with no text, now."""
    if not text:
        return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        moment = datetime.datetime.fromisoformat(text)
    except ValueError:
        view.refuse("--at must be an RFC3339 time, got " + text, "for example 2026-11-12T09:30:00Z")
    if moment.tzinfo is None:
        view.refuse("--at must carry a zone, got " + text, "for example 2026-11-12T09:30:00Z")
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fetch(name):
    """The row of a ticket id, or of a task name (metadata.task)."""
    run = subprocess.run([WRAPPER, "show", name, "--json"], capture_output=True, text=True, check=False)
    if run.returncode == 0 and run.stdout.strip():
        found = json.loads(run.stdout)
        return found[0] if isinstance(found, list) else found
    for row in json.loads(bd("list", "--all", "--limit", "0", "--json")) or []:
        if (row.get("metadata") or {}).get("task") == name:
            return row
    view.refuse('Task "%s" not found in this backlog' % name, "Run `jg-backlog.sh list` to see existing tasks", "NOT_FOUND", 1)


def flags(args, names):
    found, rest = view.flags(args, names, ())
    return found, rest


def done(started, line):
    print("%s (%.3f s)" % (line, time.monotonic() - started))


def moment(args):
    found, ids = flags(args, ("--at", "--returned-to"))
    if len(ids) != 2 or ids[1] not in MOMENTS:
        view.refuse("usage: moment <ticket> <%s> [--at <RFC3339>]" % "|".join(MOMENTS))
    started, (ticket, name) = time.monotonic(), ids
    row = fetch(ticket)
    when, source_kind = utc(found.get("--at")), MOMENTS[name]
    held = str((row.get("metadata") or {}).get(name) or "")
    if held > when:
        view.refuse("%s is already %s, later than %s: a moment is never moved back" % (name, held, when), "Give a later --at", "MOMENT_BACK", 1)
    payload = {"moment": name}
    meta = ["--set-metadata", "%s=%s" % (name, when)]
    if name == "returned_at":
        to = found.get("--returned-to") or "building"
        if to not in rule.words("ticket"):
            view.refuse("--returned-to must be a stage of the ticket machine, got " + to)
        payload["returned_to"] = to
        meta += ["--set-metadata", "returned_to=" + to]
    # The event first, then the row: the row write is what a reader polls.
    bd("provenance", "record", "--issue", row["id"], "--kind", source_kind[1], "--source", source_kind[0], "--at", when,
       "--payload", json.dumps(payload, sort_keys=True))
    bd("update", row["id"], *meta)
    done(started, "ok: %s %s = %s" % (row["id"], name, when))


def wait(args):
    found, ids = flags(args, ("--at",))
    if len(ids) not in (2, 3):
        view.refuse("usage: wait <ticket> <who> [<reason>] [--at <RFC3339>]")
    started, ticket, who, why = time.monotonic(), ids[0], ids[1], (ids[2] if len(ids) == 3 else "")
    if who not in rule.words("ticket-wait"):
        view.refuse("who must be one of %s, got %s" % (", ".join(rule.words("ticket-wait")), who))
    if why and why not in rule.words("ticket-wait-reason"):
        view.refuse("reason must be one of %s, got %s" % (", ".join(rule.words("ticket-wait-reason")), why))
    if who != "none" and not why:
        view.refuse("a wait on %s needs a reason" % who, "usage: wait <ticket> <who> <reason>")
    row = fetch(ticket)
    bd("update", row["id"], "--set-metadata", "wait=" + who, "--set-metadata", "wait_reason=" + why, "--set-metadata", "wait_at=" + utc(found.get("--at")))
    done(started, "ok: %s wait = %s%s" % (row["id"], who, " (%s)" % why if why else ""))


def ticket_stage(args):
    found, ids = flags(args, ("--proof",))
    if len(ids) != 1:
        view.refuse("usage: ticket-stage <ticket> [--proof <state>]")
    proof = found.get("--proof") or "planned"
    if proof not in rule.proving_words():
        view.refuse("--proof must be a state of the proof run, got " + proof)
    name, health = rule.word(fetch(ids[0]), proof=proof, now=utc(""))
    print("%s\t%s" % (name, health))


def main(verb, args):
    {"moment": moment, "wait": wait, "ticket-stage": ticket_stage}[verb](args)
