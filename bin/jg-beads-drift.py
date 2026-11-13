#!/usr/bin/env python3
"""jg-beads-drift.py - the observer's drift check: a row whose moments and the records outside Beads differ gets health `lost`.

Usage: import it as __import__("jg-beads-drift") and call drift(row, landings, pr_merged), the function jg-beads-moment.py's `ticket-drift` verb uses.

The row is the evidence for what the ticket did, and the records outside Beads (the trunk's landing record, the forge) are the evidence for
what happened to its commit. The two differ in two ways this check names:
  - the trunk landed the row's commit (a row of data/trunk-landings.tsv names its task) and the row has no `landed_at`, unless the landing
    was taken back (a `revert-<task>` row);
  - the row's pull request is merged on the forge and the row is neither released nor closed.
It only reads: it never writes a moment, and it returns the lines, one per difference, so a row that agrees returns none.
"""
import os
import re
import subprocess

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PR = re.compile(r"https://github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)\Z")


def names(row):
    """Every name a record outside Beads may call the ticket: its id and the task id it was spawned under."""
    meta = row.get("metadata") or {}
    return {n for n in (row.get("id"), meta.get("task")) if n}


def landings(path):
    """The landing record of the trunk: {task: commit} for each landed lane and the set of tasks taken back."""
    landed, reverted = {}, set()
    try:
        with open(path) as handle:
            for line in handle:
                cols = line.rstrip("\n").split("\t")
                if cols[0].startswith("revert-"):
                    reverted.add(cols[0][len("revert-"):])
                elif len(cols) >= 3:
                    landed[cols[0]] = cols[2]
    except OSError:
        pass
    return landed, reverted


def pr_merged(url):
    """True, False or None (not asked, or the forge did not answer) for the pull request of a row, read from the forge."""
    found = PR.match(url or "")
    if not found:
        return None
    script = '. "$1"; jg_pr_github_read_record "$2" "$3" "$4" && printf "%s" "$JG_PR_RECORD_MERGED"'
    run = subprocess.run(["bash", "-c", script, "_", os.path.join(ROOT, "bin", "jg-pr-lib.sh"), *found.groups()],
                         capture_output=True, text=True, check=False, timeout=15)
    return {"true": True, "false": False}.get(run.stdout.strip()) if run.returncode == 0 else None


def drift(row, landed, reverted, merged=None):
    """Return the drift lines for one row; each line is health `lost`. `landed` and `reverted` come from landings(), `merged` from pr_merged()."""
    meta, found = row.get("metadata") or {}, []
    mine = names(row)
    commits = [landed[n] for n in sorted(mine) if n in landed]
    if commits and not meta.get("landed_at") and not mine & reverted:
        found.append("the trunk landed commit %s and the row has no landed_at" % commits[0][:12])
    if merged and row.get("status") != "closed" and not meta.get("released_at"):
        found.append("pull request %s is merged and the row is %s" % (row.get("external_ref"), row.get("status") or "open"))
    return ["drift\t%s\tlost\t%s" % (row.get("id"), line) for line in found]
