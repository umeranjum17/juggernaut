"""Run one Muster invocation using the existing board rounds and pack approval."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import handoff
import kinds
import steplib
import store
import wflib

BIN = Path(store.ROOT, "bin")


def command(home, script, args, why):
    return steplib._run(home, [BIN / f"jg-muster{script}.sh", *args], why)


def layout(home, row):
    return handoff.record(home, row, "muster")


def launch_draft(home, step, parent, root, number, inputs, needs_plan, notes):
    row = step["id"]
    title = f"Muster draft {number}"
    child = next((r for r in store.children(row) if r["title"] == title), None)
    if child is None:
        rid = store.add(row, title, steplib.project(step), step["description"], [])
        child = store.read(rid)
    child_id = child["id"]
    kinds.write(root / f"worker-{number}", child_id + "\n")
    if child["status"] != "open" or store.started(child_id):
        return
    depth = step["metadata"]["wf_arg"]
    reply = root / f"reply-{number}.json"
    plan = root / "orders/plan.json"
    previous = "\n".join(str(path) for path in inputs) or "No earlier review."
    sent_back = notes()
    instructions = f"""Draft the {depth} Muster for this ticket.
Read the working method, formats and templates in {Path(store.ROOT, '.agents/skills/muster')}.
Use the isolated project provided to you for research. Write the pack and objective journeys only under {root / 'draft'}.
The previous project version is at {root / 'base'}. Keep settled decisions unless new evidence calls a specific one into question.
Evidence from earlier steps and the decisions recorded so far:
{previous}
If the requirements frontier needs answers, write {reply} as {{"questions": [question objects]}} in the format of bin/jg-muster.sh.
Ask only the questions this round can settle, with at most five. The board handles their presentation and answers.
Once the pack and objective journeys are ready, write {reply} as {{"ready": true, "change": "slug"}}.
For complete depth omit change. For survey read the survey drafts in the evidence, ask only about gaps, and finish without a change slug.
Before reporting a ready pack, run {BIN / 'jg-muster-objectives.sh'} objectives "$PWD" --base {handoff.read(root / 'base-ref')} --draft {root / 'draft'} and save its output to {root / f'objectives-{number}.log'}.
For light or full include --change with the slug. The base objectives must pass. A survey does not run objective journeys.
Do not post a board card, approve a pack, start Blitz, or change the source project.
Keep each document's own `status:` line true, and leave every document a note does not name as it is.
Write your evidence and next step in the Recon report, then record done. Write the reply before done."""
    if sent_back:
        instructions += ("\nThe captain, War Room or Recon sent documents back. Revise each one named below in the draft "
                         "so the note is answered, or ask a question when the note cannot be settled without the captain. "
                         "A document listed to re-check was written from one that changed: change it only if it is now wrong.\n"
                         + sent_back)
    if needs_plan:
        instructions += (f"\nWith a ready pack also write the Blitz plan at {plan} and its work orders beside it. "
                         "Use the op-order format and claim the pack's journeys and charter rows on the appropriate slices. "
                         "The workflow fills in the plan name, owner ticket and manifest block.")
    steplib.brief(home, child, scout=True, content=(f"{parent['title']}\n\n{parent['description']}", instructions))
    steplib.approve(home, child, "muster")
    check = Path(store.state_dir(), "auto-dispatch.check.sh")
    if check.is_file():
        kinds.detach(home, child_id, "kick", [check])


def snapshot(home, project, root, pack):
    if (root / "base-ref").is_file():
        return
    head = steplib._run(home, ["git", "-C", project, "rev-parse", "HEAD"], "could not read the project baseline")
    base = root / "base"
    base.mkdir(exist_ok=True)
    with tempfile.TemporaryFile(dir=root) as archive:
        subprocess.run(["git", "-C", project, "archive", head], stdout=archive, check=True)
        archive.seek(0)
        subprocess.run(["tar", "-xf", "-", "-C", base], stdin=archive, check=True)
    draft = root / "draft"
    shutil.copytree(base, draft, dirs_exist_ok=True)
    if pack:
        old = Path(steplib.data_dir(home), pack["ticket"], "muster", f"pack-{pack['sha']}")
        shutil.copytree(old, draft, dirs_exist_ok=True)
    kinds.write(root / "decisions.md", "## Decisions\n")
    kinds.write(root / "base-ref", head + "\n")


def plan_needed(step, rows):
    stage = int(step["metadata"]["wf_stage"])
    for row in rows:
        meta = row["metadata"]
        if int(meta["wf_stage"]) <= stage:
            continue
        if meta["wf_kind"] == "fanout":
            return True
        if wflib.matches((meta["wf_kind"], meta["wf_arg"], 1), wflib.FANOUT_SOURCES):
            return False
    return False


def publish_plan(path, approval, row, sha):
    plan = json.loads(path.read_text())
    plan.update(plan=f"{store.task_id(row)}-plan", owner_ticket=row,
                muster=approval.plan_block(row, sha, plan.get("muster", {})))
    kinds.write(path, json.dumps(plan, indent=2) + "\n")


def advance(home, step, approval, drafts):
    row, meta = step["id"], step["metadata"]
    root = layout(home, row)
    project_name = steplib.project(step)
    project = Path(os.environ.get("JG_PROJECTS_OVERRIDE") or Path(home, "projects"), project_name)
    rows = store.steps(meta["wf_parent"])
    parent = store.read(meta["wf_parent"])
    prior = handoff.pack(home, step, rows)
    inputs = handoff.findings(home, step, rows)
    depth = meta["wf_arg"]
    needs_plan = plan_needed(step, rows)
    root.mkdir(parents=True, exist_ok=True)
    snapshot(home, project, root, prior)
    kinds.write(Path(steplib.data_dir(home), row, "muster/project"), project_name + "\n")
    ledger = drafts.Target(project_name, str(root / "draft"), row)
    decisions = root / "decisions.md"
    if depth == "survey":
        survey = Path(steplib.data_dir(home), row, "muster/survey")
        if not (survey / "gaps.md").is_file():
            command(home, "-survey", [project_name, "--ticket", row], "Muster survey refused")
        inputs += [survey]
    else:
        if not (root / "depth-recorded").is_file():
            command(home, "-depth", ["record", "--ticket", row, "--depth", depth, "--reason", "workflow step"],
                    "could not record Muster depth")
            kinds.write(root / "depth-recorded", depth + "\n")
    inputs += [decisions]
    number = 1
    while (root / f"round-{number}-closed").is_file():
        number += 1
    child = handoff.read(root / f"worker-{number}")
    reply = root / f"reply-{number}.json"
    notes = lambda: drafts.notes_for_round(ledger, number)
    if not child:
        launch_draft(home, step, parent, root, number, inputs, needs_plan, notes)
        return
    lane = store.lane_verb(child)
    if lane in ("failed", "blocked", "needs-decision"):
        raise steplib.Failed(f"Muster draft {number} ended {lane}")
    if lane != "done" and store.read(child)["status"] != "closed":
        launch_draft(home, step, parent, root, number, inputs, needs_plan, notes)
        return
    if not reply.is_file():
        raise steplib.Failed(f"Muster draft {number} did not write {reply.name}")
    # Two drafts can ask the same question. Only the first open invocation in
    # the stage posts cards, so the board never has competing open rounds.
    if any(r["status"] != "closed" and r["metadata"]["wf_kind"] == "muster"
           and r["metadata"]["wf_stage"] == meta["wf_stage"]
           and int(r["metadata"]["wf_index"]) < int(meta["wf_index"]) for r in rows):
        return
    response = json.loads(reply.read_text())
    drafts.capture(ledger, number)
    if "questions" in response:
        questions = root / f"questions-{number}.json"
        if not (root / f"round-{number}-posted").is_file():
            kinds.write(questions, json.dumps(response["questions"]))
            command(home, "", ["round", row, "--questions", questions, "--round", str(number), "--doc", decisions],
                    "Muster round refused")
            kinds.write(root / f"round-{number}-posted", "posted\n")
        status = json.loads(command(home, "", ["round-status", row, "--json"], "could not read the round"))
        if not any(int(round_["round"]) == number and round_["complete"] for round_ in status["rounds"]):
            return
        if status["owing_document"]:
            command(home, "", ["repair", row], "could not record the board answers")
        kinds.write(root / f"round-{number}-closed", "closed\n")
        return
    if response.get("ready") is not True:
        raise steplib.Failed("the Muster drafter must provide questions or a finished draft")
    if not approval.newest(row, "approve") and drafts.pending(ledger):
        # A document was sent back while this draft was ready: the next round answers it before the captain is asked.
        (root / "manifest").unlink(missing_ok=True)
        kinds.write(root / f"round-{number}-closed", "closed for a revision\n")
        return
    if depth == "survey":
        kinds.write(root / "done", "the Muster survey is ready\n")
        return
    if depth == "light" and number == 1 and not prior:
        raise steplib.Failed("light Muster needs at least one owner question")
    manifest = root / "manifest"
    sha = handoff.read(manifest)
    if not sha:
        change = response.get("change") if depth != "complete" else None
        if depth != "complete" and (not isinstance(change, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", change)):
            raise steplib.Failed("a feature pack needs its change document slug")
        objective_log = handoff.read(root / f"objectives-{number}.log").splitlines()
        if not objective_log or objective_log[-1] != "PASS":
            raise steplib.Failed("the drafter did not prove the base objective journeys")
        sha = approval.build_manifest(row, root / "draft", depth, change, root / "base")
        kinds.write(manifest, sha + "\n")
    asked = approval.newest(row, "approve")
    if not asked:
        approval.ask(row, "approve", project_name, sha)
        return
    gate = next((g for g in approval.gates_of(row) if g["id"] == asked["gate"]), None)
    if gate and gate["state"] == "open":
        return
    approval.answered_yes(row, asked)
    if asked["manifest"] != sha:
        raise steplib.Failed("the board approved a different Muster version")
    approval.saved_copy_check(row, sha)
    if needs_plan:
        path = root / "orders/plan.json"
        publish_plan(path, approval, row, sha)
        steplib._run(home, [BIN / "jg-swarm-plan-check.sh", path], "the Muster slice plan was refused")
    kinds.write(handoff.record(home, row, "pack"), json.dumps({"ticket": row, "sha": sha}) + "\n")
    kinds.write(root / "done", f"the Muster pack version {sha} was approved\n")


def schedule(home, row):
    kinds.detach(home, row, "muster-next", [sys.executable, "-B", __file__, home, row])


def start(home, step):
    schedule(home, step["id"])
    return "waits", "Muster round started"


def result(home, step):
    row = step["id"]
    done = handoff.read(layout(home, row) / "done")
    if done:
        return "done", done
    rc = handoff.read(handoff.record(home, row, "muster-next.rc"))
    if rc and rc != "0":
        log = handoff.read(handoff.record(home, row, "muster-next.log"))
        return "failed", log.splitlines()[-1] if log else f"Muster exited {rc}"
    if os.environ.get("JG_WORKFLOW_DRY_RUN") != "1":
        schedule(home, row)
    return "open", "Muster is drafting or waiting for the board"


if __name__ == "__main__":
    home, row = sys.argv[1:]
    os.environ["JG_HOME"] = home
    sys.path.insert(0, str(Path(store.ROOT, "core/muster")))
    import approval
    import drafts

    try:
        advance(home, store.read(row), approval, drafts)
    except (approval.Refused, steplib.Failed, wflib.Refused, OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
