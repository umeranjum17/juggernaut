#!/usr/bin/env python3
"""jg-beads-lease.py - the adapter verbs for a worker's lease: beat and reclaim.

Usage: BEADS_DIR=<store> JG_BACKLOG_LANE=<agent name> jg-beads-write.py beat <ticket>
       BEADS_DIR=<store> jg-beads-write.py reclaim [--report] [--grace <seconds>] [--keep <ticket>]...

A claim carries a lease of 300 s that only `bd heartbeat` takes and refreshes, and only for the row's owner. The lease lives in bd's
node-local table, so no heartbeat writes a commit or a history line, and the in-progress read (never the changes read) shows it as
lease_expires_at. The home's own scripts send every beat, as the worker's agent name: no pane writes its own row.
beat refreshes the lease of <ticket> as JG_BACKLOG_LANE. A row that is not in progress (a hold, a date, closed, open) has no lease by bd's own
rule, so bd's refusal prints `beat <ticket> held (<status>)` and exits 0: a hold is a wait, not a fault, and the next beat after it takes a new lease.
A row another name owns exits 13 and changes nothing. Any other refusal is bd's own text, with its exit status, so the caller tries again.
reclaim returns to ready each row in progress whose lease expired more than --grace seconds ago (default 600, twice the lease, as bd advises),
except the tickets named by --keep: the caller names every ticket this home holds a task record for, because a lane with a record keeps its
row whatever its pane does, and recovery of that lane stays with the supervisor. bd clears the assignee and records the lost lease; each line
names who lost the row. A row with no lease at all is left alone. With --report nothing is written and each line starts `would reclaim`.
"""
import datetime
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
view = __import__("jg-beads-view")

WRAPPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "jg-beads.sh")
OWNED = 13
GRACE = 600


def run(*args):
    return subprocess.run([WRAPPER, *args], capture_output=True, text=True, check=False)


def refresh(ident):
    """Send one heartbeat as the worker and return its outcome (`refreshed`, `held`, `owned` or `failed`) with bd's words."""
    done = run("heartbeat", ident)
    said = (done.stdout + done.stderr).strip()
    status = re.search(r"not claimable: \S+ status (\w+)", said)
    if not done.returncode:
        return "refreshed", ""
    if status:
        return "held", status.group(1)
    return ("owned" if "already claimed by" in said else "failed"), said


def beat(args):
    _, ids = view.flags(args, (), ())
    if len(ids) != 1 or not os.environ.get("JG_BACKLOG_LANE"):
        view.refuse("beat takes one ticket and the worker's name in JG_BACKLOG_LANE", "usage: JG_BACKLOG_LANE=<agent name> the backlog beat <ticket>")
    outcome, said = refresh(ids[0])
    if outcome == "refreshed":
        print("beat %s lease refreshed" % ids[0])
    elif outcome == "held":
        print("beat %s held (%s)" % (ids[0], said))
    else:
        sys.stderr.write(said + "\n")
        sys.exit(OWNED if outcome == "owned" else 1)


def expired(row, now):
    """Return the seconds since the lease of an in-progress row ran out, or None for a row with no lease."""
    stamp = row.get("lease_expires_at")
    if not stamp:
        return None
    return (now - datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))).total_seconds()


def reclaim(args):
    found, ids = view.flags(args, ("--grace", "--keep"), ("--report",))
    if ids:
        view.refuse("reclaim takes no ticket: name the tickets to keep with --keep", "usage: the backlog reclaim [--report] [--grace <seconds>] [--keep <ticket>]...")
    grace = int(found.get("--grace") or GRACE)
    keep = set(found.get("--keep+", []))
    listed = run("list", "--status", "in_progress", "--limit", "0", "--json")
    if listed.returncode:
        sys.stderr.write(listed.stdout + listed.stderr)
        sys.exit(listed.returncode)
    now = datetime.datetime.now(datetime.timezone.utc)
    for row in json.loads(listed.stdout or "[]"):
        late = expired(row, now)
        if row["id"] in keep or late is None or late < grace:
            continue
        who = row.get("assignee") or "no one"
        if found.get("--report"):
            print("would reclaim %s from %s (lease out %d s)" % (row["id"], who, late))
            continue
        done = run("reclaim", "--id", row["id"], "--older-than", "%ds" % grace)
        if done.returncode:
            sys.stderr.write(done.stdout + done.stderr)
            sys.exit(done.returncode)
        print("reclaimed %s from %s (lease out %d s)" % (row["id"], who, late))


def main(verb, args):
    {"beat": beat, "reclaim": reclaim}[verb](args)
