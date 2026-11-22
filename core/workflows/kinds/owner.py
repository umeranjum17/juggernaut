"""Hold a plan for its own board answer, then verify the signed approval for every row it covers."""
import json
import os
from pathlib import Path
import re
import subprocess

import handoff
import kinds
import steplib
import store
import wflib

BIN = Path(store.ROOT) / "bin"


def sources(step, rows, report_kinds):
    return handoff.sources(step, rows, lambda meta: wflib.matches((meta["wf_kind"], meta["wf_arg"], 1), report_kinds))


def council_handoffs(home, step, rows):
    """Councils in the nearest report stage once they have all asked for plan approval."""
    councils = [r["id"] for r in sources(step, rows, wflib.REPORTS) if r["metadata"]["wf_kind"] == "war-room"]
    # The war room publishes plan-asked after its plan-approval hold succeeds.
    plans = Path(steplib.data_dir(home)) / "war-room"
    return councils if all((plans / row / "plan-asked").is_file() for row in councils) else []


def unblocked(home, step, rows, pending, _dry):
    return pending.issubset(council_handoffs(home, step, rows))


def _hold(home, *argv, signer=""):
    tool = os.environ.get("JG_WORKFLOW_HOLD") or BIN / "jg-captain-hold.sh"
    env = {**os.environ, "JG_HOME": home}
    if signer:
        tool = Path(signer) / "bin/jg-captain-hold.sh"
        env["JG_CAPTAIN_HOLD_SIGNER_HOME"] = signer
    return subprocess.run([tool, *argv], env=env, capture_output=True, text=True)


def markers():
    return Path(store.state_dir()) / "workflow-cards"


def cards_for(row):
    cards = {}
    for path in markers().iterdir() if markers().is_dir() else ():
        if path.is_file() and not re.search(r"\.\d+\.tmp$", path.name):
            fields = path.read_text().rstrip("\n").split("\t")
            if len(fields) == 7 and fields[1] == row:
                cards[path.name] = fields[-1].split(",")
    return cards


def hold_key(home, row):
    identity = _hold(home, "open", row, "--identity")
    if identity.returncode != 0:
        raise steplib.Failed(f"could not read the plan approval hold on {row}: {identity.stderr.strip()}")
    return steplib._run(home, ["bash", "-c", '. "$1"; jg_question_hold_card_key "$2" "$3"',
                              "_", BIN / "jg-question-lib.sh", row, identity.stdout.strip()],
                        "could not read the hold card key")


def advertised_card(home, row, hold):
    output = hold.stdout + hold.stderr
    if hold.returncode != 0:
        if hold.returncode == 1 and "no board card was posted" in output:
            return ""
        raise steplib.Failed(output.strip() or f"holding {row} exited {hold.returncode}")
    match = re.search(rf"^board card ([\w.-]+) posted for {re.escape(row)}$", output, re.M)
    if match:
        return match[1]
    return hold_key(home, row) if f"sign-off card on the board for {row}" in output else ""


def plan_counts(home, plans, rows, step):
    if not plans:
        build_stages = [int(r["metadata"]["wf_stage"]) for r in rows if r["metadata"]["wf_kind"] in wflib.BUILDS
                        and int(r["metadata"]["wf_stage"]) > int(step["metadata"]["wf_stage"])]
        total = build_stages.count(min(build_stages)) if build_stages else 0
        return total, total
    first_wave, total = 0, 0
    for plan in plans:
        checked = steplib._run(home, [BIN / "jg-swarm-plan-check.sh", plan], "the plan check refused")
        first_wave += int(checked.splitlines()[0].split()[2])
        total += int(checked.splitlines()[-1].split()[-3])
    return total, first_wave


def start(home, step):
    row, ticket = step["id"], store.read(step["metadata"]["wf_parent"])
    rows = store.steps(ticket["id"])
    councils = council_handoffs(home, step, rows)
    data = Path(steplib.data_dir(home))
    plans = handoff.plans(home, step, rows)
    if councils:
        plans = [Path((data / "war-room" / c / "plan-asked").read_text().strip()) for c in councils]
    total, wave = plan_counts(home, plans, rows, step)
    if plans:
        handoff.select(home, row, plans)
    reports = [data / store.task_id(r["id"]) / "report.md" for r in sources(step, rows, wflib.REPORTS)
               if r["metadata"]["wf_kind"] in wflib.REPORTS]
    reports = [p for p in reports if p.is_file()]
    subject = ticket.get("metadata", {}).get("workflow_subject") or ticket["title"]
    subject = " ".join(subject.split()[:8]).rstrip("?.!")
    title = f"Approve the plan for {subject}?"
    why = f"The plan builds {total} parts; {wave} start at once when you approve."
    options = ["Approve: build the plan as written", "Not yet: I will say what to change"]
    outcomes = ["Building starts at once on every ready part.", "Nothing is built until you say what to change."]
    recommendation = "The plan passed its own checks."
    ref = f"{row}-plan"
    try:
        steplib._run(home, ["bash", "-c", '. "$1"; shift; jg_ask_card_refusal "$@"', "_", BIN / "jg-ask-gate-lib.sh",
                           ref, "2", title, why, *options, *outcomes, recommendation], "plan card refused")
    except steplib.Failed as e:
        steplib._run(home, [BIN / "jg-inbox.sh", "note", "--request-id", f"wf-subject-{row}", "--",
                           f"{e}. Give {ticket['id']} a plain subject with --subject."], "could not tell Main")
        raise steplib.Failed(f"{e}. Give the ticket a plain subject with --subject.") from e
    existing = cards_for(row)
    plan_paths, report_paths = (", ".join(map(str, paths)) for paths in (plans, reports))
    for held in councils or [row]:
        if any(held in ids for ids in existing.values()):
            continue
        if councils:
            candidate = hold_key(home, held)
            known = steplib._run(home, ["bash", "-c", '. "$1"; jg_question_open_keys', "_",
                                        BIN / "jg-question-lib.sh"], "could not look up the council's card").splitlines()
            card = candidate if candidate in known or (Path(store.state_dir()) / "board-routes" / candidate).is_file() else ""
        else:
            card = advertised_card(home, held, _hold(home, "hold", held, "--reason", f"Plan approval for {subject}",
                                                    "--must", "plan-approval"))
        tag = store.task_id(row).removeprefix("jg-")
        key = f"wf-{store.task_id(row)}-plan"
        if len(councils) > 1:
            key = f"{key}-{store.task_id(held)}"
            tag = f"{tag}-{store.task_id(held)}"
        yes, no = ("yes", "no") if card else (f"a-{tag}", f"b-{tag}")
        if not card:
            argv = [BIN / "jg-question-card.sh", "post", "--ask-ref", ref, "--key", key, "--ticket", ticket["id"],
                    "--route", "main", "--must", "plan-approval", "--title", title, "--why", why]
            for value, option, outcome in zip((yes, no), options, outcomes):
                argv += ["--option", f"{value}={option}", "--outcome", f"{value}={outcome}"]
            posted = subprocess.run(argv + ["--recommend", yes, "--recommend-reason", recommendation, "--default", no],
                                    env={**os.environ, "JG_HOME": home}, capture_output=True, text=True)
            if posted.returncode != 0:
                raise steplib.Failed((posted.stderr or posted.stdout).strip() or f"card post exited {posted.returncode}")
            card = key
        fields = (ticket["id"], row, tag, plan_paths, report_paths, f"{yes},{no}", held)
        kinds.write(str(markers() / card), "\t".join(fields) + "\n")
    if plans or reports:
        steplib._run(home, [BIN / "jg-inbox.sh", "note", "--request-id", f"wf-plan-{row}", "--",
                           f"Plan approval is on the board for {ticket['id']}.\nPlan: {plan_paths}\nReport: {report_paths}"],
                     "could not tell Main where the plan is")
    return "waits", "the owner's yes is asked for"


def result(home, step):
    row = step["id"]
    cards = cards_for(row)
    try:
        records = (Path(kinds.data_dir(home)) / f"{row}.answer").read_text().splitlines()
    except FileNotFoundError:
        records = []
    latest = {fields[3]: fields[0] for line in records if len(fields := line.split("\t", 3)) == 4}
    if not cards or any(latest.get(card) != "a" for card in cards):
        return "open", "waiting for the owner"
    held_rows = {r for ids in cards.values() for r in ids}
    rows = {r["id"]: r for r in store.children(step["metadata"]["wf_parent"])}
    if not held_rows.issubset(rows):
        return "open", "waiting for the approved rows"
    bodies = "".join(f'{r}\t{json.dumps(rows[r]["description"])}\n' for r in sorted(held_rows))
    verified = subprocess.run(["bash", "-c", '''
        . "$1/jg-squad-lead-parent-lib.sh"
        . "$1/jg-captain-ask-lib.sh"
        while IFS=$'\t' read -r id body; do
            captain_ask_approved_ref "$id" "  body: $body" >/dev/null || exit 1
        done
    ''', "_", BIN], input=bodies, text=True, env={**os.environ, "STATE": store.state_dir()}, capture_output=True)
    return ("done", "the owner answered") if verified.returncode == 0 else ("open", "waiting for a verified approval")
