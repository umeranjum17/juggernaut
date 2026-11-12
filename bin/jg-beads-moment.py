#!/usr/bin/env python3
"""jg-beads-moment.py - the adapter verbs that write a ticket's moments and wait, and read its stage.

Usage: BEADS_DIR=<store> jg-beads-write.py moment <ticket> <moment> [--at <RFC3339>] [--returned-to <stage>]
       BEADS_DIR=<store> jg-beads-write.py wait <ticket> <who> [<reason>] [--at <RFC3339>]
       BEADS_DIR=<store> jg-beads-write.py ticket-stage <ticket> [--proof <state of the proof run>]
       BEADS_DIR=<store> jg-beads-write.py ticket-drift <ticket> [--forge]
       BEADS_DIR=<store> jg-beads-write.py times <ticket>

moment writes one of eight moments of the ticket machine: approved_at, proved_at, bypassed_at, landing_at, gated_at, returned_at, conflict_at and release_opened_at.
Each is a provenance event first and then the row's metadata, in that order, because the row write is the signal a reader can poll and
the event alone leaves no trace on the row. The event carries the time given by --at (else now), so the id of the event is the same
when a writer fires twice. The metadata value is that time as an RFC3339 string in UTC, so two moments compare as text. A moment is
never removed: a time earlier than the one already on the row is refused, and a later one replaces it. returned_at also writes
returned_to (default building), the stage the ticket was given back to.
wait writes the three wait keys, wait (who owes the next move), wait_reason and wait_at, in one update; a wait ends by writing the
who `none`. The words are the closed lists of core/machines/ticket-wait.states and ticket-wait-reason.states. A wait adds no child row.
No stage word is stored, `bd set-state` is never called, and hold_kind is not written: the stage is worked out by bin/jg-beads-stage.py.
times prints one line `<name><TAB><time>` for each of ready, landed, live and released that the row holds, in that order, and nothing, with exit 0,
for a row that holds none. The time is the row's RFC3339 string (ready_at, landed_at, live_at, released_at). It never writes.
Every write prints one line with the seconds it took.
ticket-drift prints one line `drift<TAB><ticket><TAB>lost<TAB><difference>` for each way the row and the records outside Beads differ
(bin/jg-beads-drift.py) and nothing when they agree. The forge is read only with --forge. It never writes.
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
drifts = __import__("jg-beads-drift")

WRAPPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "jg-beads.sh")
# moment -> (provenance source, kind). bd has fixed kinds, so the source tells the moments apart.
MOMENTS = {
    "approved_at": ("jg-approve", "claim"),
    "proved_at": ("jg-prove", "used"),
    "bypassed_at": ("jg-bypass", "used"),
    "landing_at": ("jg-trunk-landing", "land"),
    "gated_at": ("jg-trunk-gate", "land"),
    "returned_at": ("jg-trunk-return", "resume"),
    "conflict_at": ("jg-trunk-conflict", "land"),
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
    if name == "bypassed_at":
        payload["mark"] = "unproved"  # the trace says it: no proof ran for this ticket
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


def wait_flags(who, why, at=""):
    """Return the flags that write the three wait keys (wait, wait_reason, wait_at); a word outside the closed lists is refused."""
    if who not in rule.words("ticket-wait"):
        view.refuse("who must be one of %s, got %s" % (", ".join(rule.words("ticket-wait")), who))
    if why and why not in rule.words("ticket-wait-reason"):
        view.refuse("reason must be one of %s, got %s" % (", ".join(rule.words("ticket-wait-reason")), why))
    if who != "none" and not why:
        view.refuse("a wait on %s needs a reason" % who, "usage: wait <ticket> <who> <reason>")
    return ["--set-metadata", "wait=" + who, "--set-metadata", "wait_reason=" + why, "--set-metadata", "wait_at=" + utc(at)]


def wait(args):
    found, ids = flags(args, ("--at",))
    if len(ids) not in (2, 3):
        view.refuse("usage: wait <ticket> <who> [<reason>] [--at <RFC3339>]")
    started, ticket, who, why = time.monotonic(), ids[0], ids[1], (ids[2] if len(ids) == 3 else "")
    meta = wait_flags(who, why, found.get("--at"))
    row = fetch(ticket)
    bd("update", row["id"], *meta)
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


def ticket_drift(args):
    switches, ids = view.flags(args, (), ("--forge",))
    if len(ids) != 1:
        view.refuse("usage: ticket-drift <ticket> [--forge]")
    row = fetch(ids[0])
    data = os.environ.get("JG_DATA_OVERRIDE") or os.path.join(os.environ.get("JG_HOME") or os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."), "data")
    landed, reverted = drifts.landings(os.path.join(data, "trunk-landings.tsv"))
    merged = drifts.pr_merged(row.get("external_ref")) if "--forge" in switches else None
    for line in drifts.drift(row, landed, reverted, merged):
        print(line)


# The stamps `times` reads, in the order a ticket reaches them: name -> the row's metadata key.
TIMES = (("ready", "ready_at"), ("landed", "landed_at"), ("live", "live_at"), ("released", "released_at"))


def times(args):
    _, ids = view.flags(args, (), ())
    if len(ids) != 1:
        view.refuse("usage: times <ticket>")
    meta = fetch(ids[0]).get("metadata") or {}
    for name, key in TIMES:
        if meta.get(key):
            print("%s\t%s" % (name, meta[key]))


def main(verb, args):
    {"moment": moment, "wait": wait, "ticket-stage": ticket_stage, "ticket-drift": ticket_drift, "times": times}[verb](args)
