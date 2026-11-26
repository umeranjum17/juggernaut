"""Run a workflow row as a war-room council until its plan is ready for approval."""
import os
from pathlib import Path
import subprocess
import time

import handoff
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
    rows = store.steps(parent["id"])
    aligned = [r for r in rows if r["metadata"]["wf_kind"] == "muster"]
    env = {**os.environ, "JG_HOME": home}
    project = ["--project", steplib.project(step)]
    profile = ["--harness", harness, "--model", model, "--effort", effort]
    command = "start"
    if aligned:
        pack = handoff.pack(home, step, rows)
        later = any(int(r["metadata"]["wf_stage"]) > int(meta["wf_stage"]) for r in aligned)
        env.update(JG_WAR_ROOM_WORKFLOW_PARENT=parent["id"], JG_WAR_ROOM_WORKFLOW_PACK=pack["ticket"] if pack else "",
                   JG_WAR_ROOM_WORKFLOW_SHA=pack["sha"] if pack else "", JG_WAR_ROOM_WORKFLOW_REVIEW=str(int(bool(pack))))
        if later and pack is None:
            command = "discover"
    argv = _command(command, row) + project
    argv += (["--angles", angles] + profile + mode) if command == "start" else profile
    p = subprocess.run(argv, env=env, stdout=subprocess.PIPE,
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
    if record.get("kind") == "discovery":
        titles = {f"{lens} lens" for lens in record["lenses"].split(",")} | {"Muster discovery Recon"}
        critics = {"Muster discovery Recon"}
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
    plan_ready = (council / "plan-ready").is_file()
    discovery_ready = (Path(steplib.data_dir(home), row, "muster/discovery/findings.md")).is_file()
    plan_asked = (council / "plan-asked").is_file()
    if plan_ready or discovery_ready or plan_asked:
        if any(child["status"] != "closed" for child in store.children(row)):
            return "open", "waiting for the council's remaining work"
        if plan_ready:
            return "done", "the reviewed slice plan is ready"
        if discovery_ready:
            return "done", "the reviewed discovery is ready"
        # The owner step adopts the hold while the council stays open.
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
    if os.environ.get("JG_WORKFLOW_DRY_RUN") != "1" and (
        time.time() - last >= NEXT_INTERVAL or any(_mtime(state_dir / f"{task}.status") > last for task, _ in lanes)
    ):
        kinds.detach(home, row, "next", _command("next", row))
    return "open", "the council is in progress"
