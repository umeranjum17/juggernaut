"""store: the one place the workflow commands read and write the backlog. `set` and `show` import this and never
call the backlog themselves, so when the store plan renames a call, only this file changes.

Reads and the metadata write go through core/item-store/adapters/bd_compat.py, the command bin/jg-plan-file.sh's
`set_fields` uses, because `jg-backlog.sh show` does not print metadata. Rows are filed and closed through
bin/jg-backlog.sh, so its intake and ask guards apply to a step row as to any other. JG_HOME must be set."""
import json
import os
import subprocess

import wflib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BD = ["python3", "-I", os.path.join(ROOT, "core", "item-store", "adapters", "bd_compat.py")]
BACKLOG = os.path.join(ROOT, "bin", "jg-backlog.sh")


def home():
    h = os.environ.get("JG_HOME")
    if not h:
        wflib.refuse("JG_HOME is not set; a workflow is written into one home's backlog")
    return h


def state_dir():
    return os.environ.get("JG_STATE_OVERRIDE") or os.path.join(home(), "state")


def _run(argv, what):
    env = dict(os.environ, JG_HOME=home(), JG_CONFIG_OVERRIDE=os.path.join(home(), "config"))
    p = subprocess.run(argv, env=env, capture_output=True, text=True)
    if p.returncode != 0:
        wflib.refuse(f"{what}: {(p.stdout + p.stderr).strip() or 'exit ' + str(p.returncode)}")
    return p.stdout


def read(row):
    """The row as the store holds it (id, title, description, status, labels, metadata, ...), or None when there is none."""
    env = dict(os.environ, JG_HOME=home())
    p = subprocess.run(BD + ["show", row, "--json"], env=env, capture_output=True, text=True)
    try:
        rows = json.loads(p.stdout)
    except ValueError:
        return None
    return rows[0] if p.returncode == 0 and rows and rows[0].get("id") == row else None


def children(ticket):
    """Every child row of the ticket, open or closed."""
    return json.loads(_run(BD + ["list", "--parent", ticket, "--all", "--limit", "0", "--json"], f"cannot list the rows of {ticket}") or "[]")


def add(ticket, title, repo, body, blocked_by):
    """File one child row of the ticket; the new row's id."""
    argv = [BACKLOG, "add", "--parent", ticket, title, "--repo", repo, "--priority", "2", "--body", body, "--json"]
    for dep in blocked_by:
        argv += ["--blocked-by", dep]
    made = json.loads(_run(argv, f"could not file '{title}'"))
    return (made.get("task") or made)["id"]


def done(row, reason):
    _run([BACKLOG, "done", row, "--note", reason], f"could not close {row}")


def set_meta(row, fields):
    argv = BD + ["update", row]
    for k, v in fields.items():
        argv += ["--set-metadata", f"{k}={v}"]
    _run(argv, f"could not write the fields of {row}")


def task_id(row):
    """The task id of a row (bin/jg-backlog-lib.sh jg_backlog_task_id: every dot becomes a dash)."""
    return row.replace(".", "-")


def started(row):
    """Why a step row counts as started: a lane record or a dispatch approval names it; else None."""
    state = state_dir()
    if os.path.exists(os.path.join(state, task_id(row) + ".meta")):
        return "a lane record"
    if os.path.exists(os.path.join(state, "dispatch-approved", row)):
        return "a dispatch approval"
    return None


def lane_verb(row):
    """The last status verb of the row's lane, or `no lane` when no lane record exists."""
    state = state_dir()
    if not os.path.exists(os.path.join(state, task_id(row) + ".meta")):
        return "no lane"
    try:
        with open(os.path.join(state, task_id(row) + ".status")) as f:
            last = [x for x in f.read().splitlines() if x.strip()][-1]
    except (OSError, IndexError):
        return "no status"
    return last.split(None, 1)[0].rstrip(":")


def steps(ticket):
    """The live step rows of the ticket (not superseded), in stage and index order."""
    rows = [r for r in children(ticket)
            if (r.get("metadata") or {}).get("wf_parent") == ticket and not (r.get("metadata") or {}).get("wf_superseded")]
    return sorted(rows, key=lambda r: (int(r["metadata"]["wf_stage"]), int(r["metadata"]["wf_index"])))
