"""Run a workflow row as a war-room council until its plan is ready for approval."""
import os
from pathlib import Path
import subprocess
import time

import kinds
from rounds import rounds
import steplib
import store
import wflib

NEXT_INTERVAL = 60
REFUSALS = ("not started:", "not assigned:", "owner approval not asked:", "jg-war-room:")


def _command(action, row):
    return [steplib._tool("JG_WORKFLOW_WAR_ROOM", "jg-war-room.sh"), action, row]


def start(home, step):
    row, meta = step["id"], step["metadata"]
    parent = store.read(meta["wf_parent"])
    if parent is None:
        return "failed", f"cannot read the workflow of {meta['wf_parent']}"
    angles = (parent.get("metadata") or {}).get("workflow_angles") or ",".join(wflib.angles())
    harness, model, effort = wflib.route("war-room")
    mode = (["--depth", "deep"] if meta.get("wf_arg") == "full" else
            ["--depth", "standard", "--synthesis-depth", "deep", "--no-variant-critics"])
    argv = _command("start", row) + ["--project", steplib.project(step), "--angles", angles,
                                    "--harness", harness, "--model", model, "--effort", effort] + mode
    p = subprocess.run(argv, env={**os.environ, "JG_HOME": home}, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True)
    if p.returncode == 0:
        return "started", "the council started"
    lines = p.stdout.strip().splitlines()
    why = next((line for line in lines if "not started" in line), None)
    return "failed", why or (lines[-1] if lines else f"war-room start exited {p.returncode}")


def _read(path):
    try:
        return path.read_text()
    except FileNotFoundError:
        return ""


def _mtime(path):
    try:
        return path.stat().st_mtime
    except FileNotFoundError:
        return 0


def _lanes(row, record):
    variant_titles = {f"{angle.strip()} variant Recon" for angle in record.get("angles", "").split(",") if angle.strip()}
    titles = variant_titles | {"synthesis Recon", "dry run of order 1"}
    critics = {"synthesis Recon"}
    if record.get("variant_critics") == "1":
        critics |= variant_titles
    children = [child for child in store.children(row) if child["title"] in titles]
    if not children:
        return []
    # The council uses the model-aware shell mapping for its lane records.
    script = '. "$1"; model=$2; shift 2; for row do jg_backlog_task_id "$row" "$model"; done'
    tasks = subprocess.check_output(
        ["bash", "-c", script, "war-room", os.path.join(store.ROOT, "bin", "jg-backlog-lib.sh"),
         record.get("model", ""), *(child["id"] for child in children)], text=True,
    ).splitlines()
    return [(task, child["title"] in critics) for task, child in zip(tasks, children)]


def result(home, step):
    row = step["id"]
    council = Path(steplib.data_dir(home), "war-room", row)
    if (council / "plan-asked").is_file():
        # The owner step adopts the hold while the council stays open.
        if any(child["status"] != "closed" for child in store.children(row)):
            return "open", "waiting for the council's remaining work"
        hold = steplib._tool("JG_WORKFLOW_HOLD", "jg-captain-hold.sh")
        phase = steplib._run(home, [hold, "phase", row], "could not read the council's plan approval")
        if phase in ("answered", "closed"):
            return "done", "the council's plan approval was answered"
        return "open", "waiting for the council's plan approval"

    jobs = Path(kinds.data_dir(home))
    rc = _read(jobs / f"{row}.next.rc").strip()
    if rc and rc != "0":
        lines = _read(jobs / f"{row}.next.log").strip().splitlines()
        why = next((line for line in reversed(lines) if any(word in line for word in REFUSALS)), None)
        return "failed", why or (lines[-1] if lines else f"war-room next exited {rc}")

    record = dict(line.split("=", 1) for line in _read(council / "record").splitlines() if "=" in line)
    if not record:
        return "open", "the council record is pending"
    lanes = _lanes(row, record)
    for task, has_critic in lanes:
        if has_critic:
            state, why = rounds(home, task, row)
            if state == "failed":
                return state, why

    last = _mtime(jobs / f"{row}.next.pid")
    state_dir = Path(store.state_dir())
    if time.time() - last >= NEXT_INTERVAL or any(_mtime(state_dir / f"{task}.status") > last for task, _ in lanes):
        kinds.detach(home, row, "next", _command("next", row))
    return "open", "the council is in progress"
