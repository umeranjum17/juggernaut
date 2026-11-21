"""steplib: what every step kind that starts a lane needs, in one place. A kind's `start` calls these and nothing else reaches the
brief, the route or the approval; `result` stays a read of the records the lane leaves.

  brief(home, step, scout)   write data/<task>/brief.md with bin/jg-brief.sh from the step's ticket and fill both Task sections
  approve(home, step, kind)  write state/dispatch-approved/<row> on the route of the kind (bin/jg-backlog.sh approve-dispatch)

A refusal of either is raised as `Failed(why)`; the pass turns it into one named alert, never a silent skip. Tests replace the
three outside tools with $JG_WORKFLOW_BRIEF, $JG_WORKFLOW_PROJECT_MODE and $JG_WORKFLOW_BACKLOG."""
import os
import re
import subprocess

import store
import wflib

ROOT = store.ROOT
PLACEHOLDER = re.compile(r"\{TASK\}|\{JUGGERNAUT_SPEC\}")


class Failed(Exception):
    pass


def _tool(env, name):
    return os.environ.get(env) or os.path.join(ROOT, "bin", name)


def _run(home, argv, what):
    p = subprocess.run(argv, env={**os.environ, "JG_HOME": home}, capture_output=True, text=True)
    if p.returncode != 0:
        last = (p.stdout + p.stderr).strip().splitlines()[-1:] or [f"exit {p.returncode}"]
        raise Failed(f"{what}: {last[0][:200]}")
    return p.stdout.strip()


def project(step):
    for label in step.get("labels") or []:
        if label.startswith("project:"):
            return label[len("project:"):]
    raise Failed(f"{step['id']} names no project")


def data_dir(home):
    return os.environ.get("JG_DATA_OVERRIDE") or os.path.join(home, "data")


def reports_before(step):
    """The report of every Recon in a stage before the step's own, as `data/<task>/report.md` lines."""
    meta, out = step["metadata"], []
    for r in store.steps(meta["wf_parent"]):
        if r["metadata"]["wf_kind"] == "recon" and int(r["metadata"]["wf_stage"]) < int(meta["wf_stage"]):
            out.append(f"data/{store.task_id(r['id'])}/report.md")
    return out


def sections(step, scout):
    """(task text, spec text): the ticket's own words, then what the lane builds or reports and what it may not widen."""
    ticket = store.read(step["metadata"]["wf_parent"])
    if ticket is None:
        raise Failed(f"cannot read the ticket {step['metadata']['wf_parent']}")
    task = [ticket["title"], "", (ticket.get("description") or "").strip(), "",
            f"This lane is step {step['metadata']['wf_index']} of stage {step['metadata']['wf_stage']} of the workflow on {ticket['id']}."]
    reports = reports_before(step)
    if scout:
        spec = ["Investigate the ticket above and write the report the Recon contract names; change no code.",
                "A build after this report starts only on the owner's recorded yes for this plan, never from the report itself."]
    else:
        spec = ["Build exactly what the ticket above asks, and nothing else.",
                "Do not widen the scope: a new idea or a gap you find is a follow-up line in your report, not this change."]
        if reports:
            spec.insert(1, "The owner approved the plan in the report(s) " + ", ".join(reports) + "; read them first and build that plan.")
    return "\n".join(task), "\n".join(spec)


def brief(home, step, scout):
    row, task = step["id"], store.task_id(step["id"])
    path = os.path.join(data_dir(home), task, "brief.md")
    if not (os.path.exists(path) and not PLACEHOLDER.search(open(path).read())):
        proj = project(step)
        argv = [_tool("JG_WORKFLOW_BRIEF", "jg-brief.sh"), task, proj, "--ticket", row]
        if scout:
            argv += ["--scout", "--depth", step["metadata"].get("wf_arg") or "standard"]
        else:
            mode = _run(home, [_tool("JG_WORKFLOW_PROJECT_MODE", "jg-project-mode.sh"), proj], "the delivery mode of " + proj).split()
            if not mode:
                raise Failed(f"the delivery mode of {proj} is not registered")
            argv += ["--mode", mode[0]]
        _run(home, argv, "the brief was not written")
        text = open(path).read()
        task_text, spec_text = sections(step, scout)
        text = text.replace("{TASK}", task_text).replace("{JUGGERNAUT_SPEC}", spec_text)
        with open(path + ".tmp", "w") as f:
            f.write(text)
        os.replace(path + ".tmp", path)
    if PLACEHOLDER.search(open(path).read()):
        raise Failed(f"the brief of {row} still holds a placeholder")
    return path


def approve(home, step, kind):
    """The dispatch approval of the step on the route of its kind (`recon(quick)` reads `recon-quick`)."""
    harness, model, effort = wflib.route(kind, step["metadata"].get("wf_arg") or None)
    _run(home, [_tool("JG_WORKFLOW_BACKLOG", "jg-backlog.sh"), "approve-dispatch", step["id"], "--harness", harness,
                "--model", model, "--effort", effort], "the start was not approved")
