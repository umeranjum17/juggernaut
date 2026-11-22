"""The artifacts one workflow step hands to another."""
import hashlib
import json
from pathlib import Path

import kinds
import steplib
import store
import wflib


def before(step, rows):
    return [row for row in rows if int(row["metadata"]["wf_stage"]) < int(step["metadata"]["wf_stage"])]


def sources(step, rows, match):
    candidates = [row for row in before(step, rows) if match(row["metadata"])]
    if not candidates:
        return []
    stage = candidates[-1]["metadata"]["wf_stage"]
    return [row for row in candidates if row["metadata"]["wf_stage"] == stage]


def record(home, row, name):
    return Path(kinds.data_dir(home), f"{row}.{name}")


def read(path):
    try:
        return path.read_text().strip()
    except FileNotFoundError:
        return ""


def pack(home, step, rows):
    for row in reversed(before(step, rows)):
        if row["metadata"]["wf_kind"] == "muster" and row["status"] == "closed":
            value = read(record(home, row["id"], "pack"))
            if value:
                return json.loads(value)
    return None


def findings(home, step, rows):
    """Accepted reports and their optional question proposals since the last pack."""
    data = Path(steplib.data_dir(home))
    previous = before(step, rows)
    barrier = max((int(row["metadata"]["wf_stage"]) for row in previous
                   if row["metadata"]["wf_kind"] == "muster" and row["metadata"]["wf_arg"] != "survey"), default=0)
    paths = []
    for row in previous:
        kind, stage = (row["metadata"][key] for key in ("wf_kind", "wf_stage"))
        if int(stage) < barrier or row["status"] != "closed":
            continue
        rid = row["id"]
        if kind == "war-room":
            council = data / "war-room" / rid
            files = (data / rid / "muster/discovery/findings.md", data / rid / "muster/discovery/round.json")
            published = read(council / "findings")
            if published:
                report = Path(published)
                files = (report, report.with_name("muster-proposals.json"))
        elif kind == "recon":
            folder = data / store.task_id(rid)
            files = (folder / "report.md", folder / "muster-proposals.json")
        elif kind == "muster" and row["metadata"]["wf_arg"] == "survey":
            survey = data / rid / "muster/survey"
            files = (*sorted(survey.glob("*.md")), record(home, rid, "muster") / "decisions.md")
        else:
            continue
        paths.extend(path for path in files if path.is_file())
    return paths


def plan(home, row):
    data = Path(steplib.data_dir(home))
    rid, kind = row["id"], row["metadata"]["wf_kind"]
    if kind == "war-room":
        council = data / "war-room" / rid
        path = read(council / "plan-ready") or read(council / "plan-asked")
        return Path(path) if path else None
    if kind == "muster":
        path = record(home, rid, "muster") / "orders/plan.json"
    else:
        path = data / store.task_id(rid) / "orders/plan.json"
    return path if path.is_file() else None


def plans(home, step, rows):
    approved = pack(home, step, rows)
    candidates = []
    for row in before(step, rows):
        meta = row["metadata"]
        if not wflib.matches((meta["wf_kind"], meta["wf_arg"], 1), wflib.FANOUT_SOURCES):
            continue
        path = plan(home, row)
        if path is None:
            continue
        if approved and meta["wf_kind"] == "muster" and row["id"] != approved["ticket"]:
            continue
        candidates.append((meta["wf_stage"], path))
    return [path for stage, path in candidates if stage == candidates[-1][0]]


def digest(path):
    """Bind the plan and the order files shown for approval."""
    content = path.read_bytes()
    result = hashlib.sha256(content)
    for item in json.loads(content)["slices"]:
        order = (path.parent / item["order"]).resolve()
        if not order.is_relative_to(path.parent.resolve()):
            raise steplib.Failed(f"the work order {item['order']} leaves its plan directory")
        result.update(hashlib.sha256(order.read_bytes()).digest())
    return result.hexdigest()


def select(home, owner, paths):
    path = record(home, owner, "plans")
    selected = json.dumps({str(p): digest(p) for p in paths})
    if path.exists() and read(path) != selected:
        raise steplib.Failed("the plan changed after it was presented for approval")
    kinds.write(path, selected + "\n")
