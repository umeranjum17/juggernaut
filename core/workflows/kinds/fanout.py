"""Start the exact slice plan the workflow owner approved."""
import fcntl
import hashlib
import json
from pathlib import Path
import re

import handoff
import steplib
import store
import wflib


def start(home, step):
    ticket = step["metadata"]["wf_parent"]
    rows = store.steps(ticket)
    owners = handoff.sources(step, rows, lambda meta: meta["wf_kind"] == "owner")
    if not owners or any(row["status"] != "closed" for row in owners):
        raise steplib.Failed("Blitz needs a completed plan approval step")
    selected = [handoff.read(handoff.record(home, row["id"], "plans")) for row in owners]
    if not selected[0] or any(item != selected[0] for item in selected):
        raise steplib.Failed("the owner step did not approve a slice plan")
    order = store.read(ticket)["metadata"]["workflow_order"]
    harness, model, effort = wflib.route("fanout")
    pack = handoff.pack(home, step, rows)
    env = {"JG_SWARM_WORKFLOW_PACK": pack["ticket"], "JG_SWARM_WORKFLOW_SHA": pack["sha"]} if pack else {}
    for name, digest in json.loads(selected[0]).items():
        plan = Path(name)
        if handoff.digest(plan) != digest:
            raise steplib.Failed(f"the approved plan or work orders changed at {plan}")
        plan_id = json.loads(plan.read_bytes())["plan"]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", plan_id):
            raise steplib.Failed("the approved plan has an invalid name")
        with handoff.record(home, plan_id, "blitz.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            text = handoff.read(Path(steplib.data_dir(home), "swarm", plan_id, "swarm.json"))
            record = json.loads(text) if text else {}
            if record.get("state") == "running":
                if record.get("source_sha256") != hashlib.sha256(plan.read_bytes()).hexdigest():
                    raise steplib.Failed(f"Blitz {plan_id} already runs a different plan")
                continue
            steplib._run(home, [steplib._tool("JG_WAR_ROOM_SWARM", "jg-swarm.sh"), "start", plan, "--wait",
                                "--order", order, "--harness", harness, "--model", model, "--effort", effort],
                         "Blitz did not start", **env)
    return "waits", "Blitz started the approved slice plan"


def result(_home, _step):
    return "done", "Blitz started the approved slice plan"
