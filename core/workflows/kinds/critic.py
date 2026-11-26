"""Start a critic on its paired draft and use rounds to close the step."""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]


def source(step, rows):
    from wflib import PLAN_SOURCES, matches, nearest

    meta = step["metadata"]
    preceding = [[] for _ in range(int(meta["wf_stage"]) - 1)]
    candidates = []
    for row in rows:
        m = row["metadata"]
        stage = int(m["wf_stage"]) - 1
        if stage < len(preceding):
            shape = m["wf_kind"], m["wf_arg"], 1
            preceding[stage].append(shape)
            if m["wf_index"] == meta["wf_index"] and matches(shape, PLAN_SOURCES):
                candidates.append((stage, row))
    target = nearest(preceding, len(preceding), PLAN_SOURCES)
    return next((row for stage, row in candidates if stage == target), None)


def draft_path(home, row, name):
    data = Path(os.environ.get("JG_DATA_OVERRIDE") or Path(home, "data"))
    return data / "workflows" / f"{row}.{name}"


def draft_version(home, row):
    """Identify the same report in the probe, advance and dispatch."""
    task = row.replace(".", "-")
    data = Path(os.environ.get("JG_DATA_OVERRIDE") or Path(home, "data"))
    try:
        report = (data / task / "report.md").stat()
    except OSError:
        return ""
    return f"{row} {report.st_ino}:{report.st_ctime_ns}:{report.st_size}"


def probe_passed(home, blocker):
    version = draft_version(home, blocker)
    try:
        return bool(version) and version == draft_path(home, blocker, "draft-proven").read_text().strip()
    except OSError:
        return False


def draft_ready(home, row, blocker):
    try:
        return (blocker in draft_path(home, row, "draft-blockers").read_text().splitlines()
                and probe_passed(home, blocker))
    except OSError:
        return False


def gate(home, task):
    p = subprocess.run([ROOT / "bin/jg-recon-gate.sh", task, "--step"], capture_output=True,
                       text=True, env={**os.environ, "JG_HOME": home}, timeout=20)
    return p.returncode == 0 and p.stdout.startswith("recon gate: STEP critic ")


def probe(home, row):
    """Run one gate per Recon outside advance and publish the passing draft version."""
    version = draft_version(home, row)
    if version and gate(home, row.replace(".", "-")):
        path = draft_path(home, row, "draft-proven")
        tmp = path.with_suffix(f".{os.getpid()}.tmp")
        tmp.write_text(version + "\n")
        tmp.replace(path)


def unblocked(home, step, rows, blockers, dry):
    import kinds
    import store

    row, stage = step["id"], step["metadata"]["wf_stage"]
    # A parallel critic stage still waits for the whole preceding stage. A Recon
    # paired to one of its critics can meet that barrier with its gated draft.
    paired = source(step, rows)
    if paired is None:
        return False
    indices = {m["wf_index"] for r in rows if (m := r["metadata"])["wf_kind"] == "critic" and m["wf_stage"] == stage}
    researchers = {r["id"] for r in rows if (m := r["metadata"])["wf_kind"] == "recon"
                   and m["wf_stage"] == paired["metadata"]["wf_stage"] and m["wf_index"] in indices
                   and m["wf_arg"] in ("standard", "deep")}
    if blockers - researchers:
        return False
    if all(draft_ready(home, row, b) for b in blockers):
        return True
    if dry or any(store.lane_verb(b) != "done" for b in blockers):
        return False
    kinds.write(draft_path(home, row, "draft-blockers"), "\n".join(sorted(blockers)) + "\n")
    for blocker in blockers:
        if not probe_passed(home, blocker):
            kinds.detach(home, blocker, "draft-probe", [sys.executable, __file__, home, blocker])
    return all(draft_ready(home, row, b) for b in blockers)


def start(home, step):
    import kinds
    import steplib
    import store

    row = step["id"]
    researcher = source(step, store.steps(step["metadata"]["wf_parent"]))
    if researcher is None:
        raise steplib.Failed(f"{row} has no paired Recon or war-room step")
    task, critic = store.task_id(researcher["id"]), store.task_id(row)
    data = Path(steplib.data_dir(home))
    path = data / critic / "brief.md"
    role = f"Role: critic of {task}"
    if not path.exists():
        steplib._run(home, [steplib._tool("JG_WORKFLOW_BRIEF", "jg-brief.sh"), critic, steplib.project(step),
                            "--scout", "--depth", "quick", "--ticket", row], "the critic brief was not written")
    text = path.read_text()
    if any(line.startswith("Recon depth:") for line in text.splitlines()):
        raise steplib.Failed(f"the critic needs a quick brief, but {path} has a Recon depth")
    if steplib.PLACEHOLDER.search(text):
        report = data / task / "report.md"
        verdict = f"`{ROOT}/bin/jg-recon-handoff.sh verdict {task} --critic {critic} --hash <sha256 of {report}> --gaps <k>`"
        spec = (f'{role}\nRead the draft with the deep-recon critic rubric (.agents/skills/deep-recon/SKILL.md, "Critic rubric").\n'
                "Write no report.md and no backlog item.\n"
                f"Write each gap as a `- ` line at the end of {data / critic / 'critic.md'} before recording the verdict.\n"
                f"End each round with {verdict}.")
        text = text.replace("{TASK}", f"You are the critic of {task}. Read its draft at {report}.")
        text = text.replace("{JUGGERNAUT_SPEC}", spec)
        body, sep, tail = text.partition("\n# Definition of done\n")
        if sep:
            _, rules, additions = tail.partition("\n# Shared worker rules\n")
            text = (f"{body}{sep}Record the verdict for the current draft, append your done line, and stop.\n"
                    f"{rules}{additions}")
        kinds.write(path, text)
    if role not in text.splitlines():
        raise steplib.Failed(f"a different brief is already at {path}")
    link = data / row / "brief.md"
    target = f"../{critic}/brief.md"
    if not link.is_symlink() or os.readlink(link) != target:
        link.parent.mkdir(parents=True, exist_ok=True)
        tmp = link.with_suffix(f".{os.getpid()}.tmp")
        tmp.symlink_to(target)
        tmp.replace(link)

    handoff = ROOT / "bin/jg-recon-handoff.sh"
    phase = steplib._run(home, [handoff, "phase", task], "the handoff phase could not be read")
    if phase == "none" and gate(home, task):
        steplib._run(home, [handoff, "draft", task], "the draft was not recorded")
    steplib._run(home, [handoff, "assign", task, "--critic", critic], "the draft was not assigned")
    steplib.approve(home, step, "critic")
    return "started", "the critic was assigned and its start approved"


def result(home, step):
    from rounds import rounds
    import store

    researcher = source(step, store.steps(step["metadata"]["wf_parent"]))
    if researcher is None:
        return "failed", "the paired Recon or war-room step is missing"
    state, why = rounds(home, store.task_id(researcher["id"]), step["id"])
    return ("done" if state == "accepted" else state), why


if __name__ == "__main__":
    probe(sys.argv[1], sys.argv[2])
