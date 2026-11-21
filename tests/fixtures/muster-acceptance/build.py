"""Stand in for the planner and deterministic builders of the fixture charter."""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

TITLES = {
    "C1": "Conversation answers with sources",
    "C2": "Command line for the bot",
    "C3": "Handoff to an agent",
    "C4": "Resolve and reopen",
    "R1": "Conversation can be rated",
    "R2": "Reopen clears the rating",
}
FILES = {
    "C1": ["src/domain/conversation.ts (new)", "src/domain/errors.ts (new)"],
    "C2": ["src/cli.ts"],
    "C3": ["src/cli.ts", "src/domain/handoff.ts (new)", "src/domain/conversation.ts"],
    "C4": ["src/cli.ts", "src/domain/conversation.ts"],
    "R1": ["src/cli.ts", "src/domain/conversation.ts"],
    "R2": ["src/domain/conversation.ts"],
}


def ids(text):
    return [] if text == "-" else text.split(",")


def make_plan(ticket, manifest, document, out):
    block = {"ticket": ticket, "manifest_sha": manifest.stem.removeprefix("manifest-"),
             "journeys": [], "batches": [], "charter": [], "milestones": []}
    for line in manifest.read_text().splitlines():
        kind, *values = line.split(" ")
        if kind == "check":
            block["depth"] = values[0]
        elif kind == "journey":
            block["journeys"].append(dict(zip(("id", "kind"), values)))
        elif kind == "batch":
            block["batches"].append({"id": values[0], "after": ids(values[1])})
        elif kind == "charter":
            block["charter"].append({"ticket": values[0], "batch": values[1], "depends": ids(values[2])})
        elif kind == "milestone":
            block["milestones"].append({"id": values[0], "journeys": ids(values[1])})
    claims = {}
    for line in document.read_text().splitlines():
        columns = [part.strip() for part in line.strip("|").split("|")]
        if len(columns) == 6 and columns[0] in TITLES:
            claims[columns[0]] = columns[-1].split(", ")
    batches = {batch["id"]: batch["after"] for batch in block["batches"]}
    slices = []
    out.parent.mkdir(parents=True, exist_ok=True)
    for row in block["charter"]:
        charter = row["ticket"]
        deps = set(row["depends"])
        deps.update(other["ticket"] for other in block["charter"] if other["batch"] in batches[row["batch"]])
        if charter == "C4":
            deps.add("C3")  # C3 and C4 both edit the conversation and CLI.
        slice_id = charter.lower()
        order = f"{slice_id}.md"
        (out.parent / order).write_text(f"# {TITLES[charter]}\n\n## Goal\n\n{TITLES[charter]}.\n\n"
                                       "## Acceptance\n\nRun the objective journeys.\n")
        slices.append({"id": slice_id, "title": TITLES[charter], "owner_home": "main", "project": "helpdesk",
                       "size": "S", "risk": "Low", "depends_on": sorted(dep.lower() for dep in deps),
                       "files": FILES[charter], "machine": None, "order": order, "owner_word": None, "gate": None,
                       "charter": [charter], "journeys": claims[charter]})
    plan = {"plan": f"jg-plan-{ticket.removeprefix('jg-')}", "title": "Build the help desk",
            "report": str(document), "intent": "Build the help desk from its approved pack.",
            "prior_art": "Prior art: none needed - the fixture exercises existing code.",
            "owner_order": "Main1", "owner_ticket": ticket, "muster": block, "slices": slices}
    out.write_text(json.dumps(plan))


def drop_methods(text, names):
    for name in names:
        text, replaced = re.subn(rf"\n  {name}\(.*?\n  \}}\n", "\n", text, count=1, flags=re.S)
        if replaced != 1:
            raise SystemExit(f"the fixture cannot find method {name}")
    return text


def run_build(project, source, terminal, plan_path, home):
    pending = json.loads(plan_path.read_text())["slices"]
    landed = set()
    (project / "src/domain").mkdir(parents=True, exist_ok=True)
    while pending:
        ready = [entry for entry in pending if set(entry["depends_on"]) <= landed]
        if not ready:
            raise SystemExit("no slice is ready on the charter")
        for entry in ready:
            charter, = entry["charter"]
            if not (home / "state/dispatch-approved" / entry["row"]).is_file():
                raise SystemExit(f"Blitz did not approve {charter}")
            (terminal / entry["task"]).write_text(charter + "\n")
            conversation = source / "src/domain/conversation.ts"
            target = project / "src/domain/conversation.ts"
            cli = (source / "src/cli.ts").read_text()
            body = conversation.read_text()
            if charter in {"C1", "C3"}:
                body = drop_methods(body, ["resolve", "reopen"])
            if charter == "C1":
                body = drop_methods(body, ["handOff"])
                body = body.replace('import { Handoff } from "./handoff.ts";', "type Handoff = never;")
                body = body.replace("    if (raw.handoff) c.handoff = Handoff.restore(raw.handoff);\n", "")
                shutil.copyfile(source / "src/domain/errors.ts", project / "src/domain/errors.ts")
            if charter == "C3":
                shutil.copyfile(source / "src/domain/handoff.ts", project / "src/domain/handoff.ts")
            if charter == "R1":
                body = body.replace("    this.rating = null;\n    this.events.push(\"Reopened\");", "    this.events.push(\"Reopened\");")
            if charter != "C2":
                target.write_text(body)
            if charter in {"C2", "C3"}:
                unavailable = ["resolve", "reopen"]
                if charter == "C2":
                    unavailable += ["handoff", "accept", "close-handoff"]
                cli = "\n".join(line for line in cli.split("\n")
                                if not any(line.startswith(f'    case "{cmd}":') for cmd in unavailable))
            if charter not in {"C1", "R2"}:
                (project / "src/cli.ts").write_text(cli)
            subprocess.run(["git", "-C", project, "add", "-A"], check=True)
            subprocess.run(["git", "-C", project, "commit", "-qm", TITLES[charter]], check=True)
            pending.remove(entry)
            landed.add(entry["id"])


mode, *args = sys.argv[1:]
if mode == "plan":
    make_plan(args[0], *map(Path, args[1:]))
elif mode == "build":
    run_build(*map(Path, args))
else:
    raise SystemExit(f"unknown fixture operation {mode}")
