"""recon: one scout lane that reports. The step is done when the report is on record, the lane's last line is `done` and the
Recon gate has passed it (core/recon-ready records that pass). A report-only workflow ends here; a build needs its own owner stage."""
import os

import steplib
import store


def start(home, step):
    steplib.brief(home, step, scout=True)
    steplib.approve(home, step, "recon")
    return "started", "the Recon brief is written and the start is approved"


def _read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def result(home, step):
    task = store.task_id(step["id"])
    if store.lane_verb(step["id"]) == "failed":
        return "failed", "the Recon lane ended failed"
    if not _read(os.path.join(steplib.data_dir(home), task, "report.md")).strip():
        return "open", "no report yet"
    if store.lane_verb(step["id"]) != "done":
        return "open", "the report is not reported done"
    if not _read(os.path.join(store.state_dir(), "recon-ready", task)).strip():
        return "open", "the report has not passed the Recon gate"
    return "done", "the report passed the Recon gate"
