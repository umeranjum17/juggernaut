#!/usr/bin/env python3
"""Make agreement with a report executable.

Usage: jg-report-actions.py lint|approve|refine|reject <report.md> [--by|--note|--reason <value>]

README.md owns the canonical Actions block, what each command does, and how one answer per
version is recorded; the page look belongs to the sign-off lead.
"""

import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DATA = Path(os.environ.get("JG_DATA_OVERRIDE") or Path(os.environ.get("JG_HOME") or ROOT) / "data")
TASKS_AXI = os.environ.get("TASKS_AXI") or ROOT / "bin/jg-tasks-axi.sh"
SEND = os.environ.get("JG_SEND") or ROOT / "bin/jg-send.sh"
HANDOFF = os.environ.get("JG_HANDOFF") or ROOT / "bin/jg-backlog-handoff.sh"
OWNER_RULES = os.environ.get("JG_OWNER_RULES") or ROOT / "bin/jg-owner-rules.sh"
REASONS = ("not-a-problem", "wrong-fix", "too-risky", "not-now", "other")
AGREEMENT = re.compile(r"\b(agree[sd]?|approve[sd]?|yes|yep|yeah|go ahead|go for it|do it|ship it|build it|implement|proceed)\b", re.I)
# Each canonical button line states its plain result before it is pressed.
LEAD = r"[A-Za-z0-9._-]+"
BLOCK = {
    "Approve": rf"- \*\*Approve\*\*( \(recommended\))?: build starts\. Owner: ({LEAD})\. First PR due: (\d{{4}}-\d{{2}}-\d{{2}})\.$",
    "Refine": rf"- \*\*Refine\*\*: your note goes to {LEAD} and a new version of this report appears with a diff\.$",
    "Reject": r"- \*\*Reject\*\*: pick a reason and add a note\. This report closes, no build starts, and the reason is saved as an owner rule\.$",
}
NOTHING = re.compile(r"^If you do nothing: nothing starts and this report stays open\.$")


def die(message):
    sys.stderr.write(f"report-actions: {message}\n")
    sys.exit(1)

def run(command):
    done = subprocess.run(command, capture_output=True, text=True)
    if done.returncode:
        die(f"{command[0]} failed: {done.stderr.strip() or done.stdout.strip()}")
    return done.stdout
def section(text, heading):
    """The lines under one "## <heading>", up to the next level-two heading."""
    found = re.search(rf"^## {heading}\s*\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    return found.group(1) if found else ""

def title(path):
    found = re.search(r"^# (.*)$", path.read_text(), re.M)
    return found.group(1).strip() if found else ""

def today():
    return time.strftime("%Y-%m-%d", time.gmtime())

def lint(path):
    """Check the block against the canonical lines; returns the Approve match."""
    if not path.is_file():
        die(f"no report file at {path}")
    block = [l for l in section(path.read_text(), "Actions").splitlines() if l.strip()]
    if not block:
        die(f"{path} has no Actions block; README.md has the block to copy")
    approved, seen, nothing = None, set(), False
    for line in block:
        if NOTHING.match(line):
            nothing = True
            continue
        for name, pattern in BLOCK.items():
            found = re.match(pattern, line)
            if not found:
                continue
            if name in seen:
                die(f"{path} repeats the {name} button")
            seen.add(name)
            approved = found if name == "Approve" else approved
            break
        else:
            die(f"{path} has a line that is not a clear button: {line}")
    if not approved:
        die(f"{path} has no Approve button, so agreement has nothing to start")
    if sum("(recommended)" in l for l in block) != 1 or not approved.group(1):
        die(f"{path} must mark exactly one button (recommended), on Approve")
    if not nothing:
        die(f"{path} must end with the 'If you do nothing:' line")
    if not re.search(r"^- ", section(path.read_text(), "Plan"), re.M):
        die(f"{path} has no plan item to mint: add '## Plan' with one '- ' line per ticket")
    return approved

def open_version(path):
    """The open version: 1 until a refine archives it as report.v1.md."""
    if (path.parent / "answered").exists():
        die(f"{path} is already answered; refine it to open the next version")
    return len(list(path.parent.glob("report.v[0-9]*.md"))) + 1

def names_report(words, path):
    low, heading = " ".join(words.lower().split()), " ".join(title(path).lower().split())
    if path.parent.name.lower() not in low and not (heading and heading in low):
        die("his words do not name this report by link or title")
    if not AGREEMENT.search(low):
        die("his words name the report but carry no agreement")
def cmd_approve(path, words):
    approved = lint(path)
    if words is not None:
        names_report(words, path)
    open_version(path)
    owner, due = approved.group(2), approved.group(3)
    place = "data/" + str(path).split("/data/", 1)[1] if "/data/" in str(path) else str(path)
    ids = []
    for line in section(path.read_text(), "Plan").splitlines():
        item = line[2:].strip() if line.startswith("- ") else ""
        if item:
            out = run([TASKS_AXI, "add", "--mint", item, "--kind", "ship",
                       "--body", f"From report: {place}. Owner: {owner}. First PR due: {due}."])
            minted = re.search(r"^ok: added ([A-Za-z0-9._-]+)", out, re.M)
            if not minted:
                die(f"could not read a ticket id from: {out.strip()}")
            ids.append(minted.group(1))
    registry = DATA / "squad_leads.md"
    if registry.is_file() and re.search(rf"^- {re.escape(owner)} - ", registry.read_text(), re.M):
        run([HANDOFF, owner, *ids])
        route = f"routed to {owner}"
    else:
        route = "queued in the main backlog"
    (path.parent / "answered").write_text(f"approve {today()} owner={owner}\n")
    print(f"started: owner {owner}; first PR due {due}; tickets {' '.join(ids)} ({route})")

def cmd_refine(path, note):
    approved = lint(path)
    if "\n" in note:
        die("refine takes a one-line note")
    version = open_version(path)
    owner, new = approved.group(2), version + 1
    archive = path.parent / f"report.v{version}.md"
    path.rename(archive)
    path.write_text(archive.read_text() + f"\n## Refined to version {new} on {today()}\n\n{note}\n")
    (path.parent / "answered").unlink(missing_ok=True)
    if subprocess.run([SEND, owner, f"Report refine ({path}): {note}"]).returncode:
        die(f"version {new} is written but his note did not reach {owner}")
    print(f"refined: version {new} is open for approval; his note is with {owner}")
    subprocess.run(["diff", "-u", str(archive), str(path)])

def cmd_reject(path, reason, note):
    if reason not in REASONS:
        die(f"reject needs --reason, one of: {' '.join(REASONS)}")
    lint(path)
    if "\n" in note:
        die("reject takes a one-line note")
    open_version(path)
    heading = title(path)
    with path.open("a") as closed:
        closed.write(f"\nClosed: rejected on {today()} - reason: {reason}" + (f"; note: {note}" if note else "") + "\n")
    (path.parent / "answered").write_text(f"reject {today()} reason={reason}\n")
    done = subprocess.run([OWNER_RULES, "add", "--title", f"{heading}: rejected ({reason})", "--scope", f"report {heading}",
                           "--words", f"report rejected ({reason})" + (f": {note}" if note else ""),
                           "--enforce", "addons/report-actions/bin/jg-report-actions.py"])
    if done.returncode:
        die(f"{path} closed, but saving his reason as an owner rule failed")
    print(f"closed: rejected ({reason}); no build; the reason is saved as an owner rule")

def main():
    if len(sys.argv) < 3:
        die(__doc__)
    command, path, rest = sys.argv[1], Path(sys.argv[2]), sys.argv[3:]
    flags = {rest[i]: rest[i + 1] for i in range(len(rest) - 1) if rest[i].startswith("--")}
    if command == "lint":
        return lint(path)
    if command == "approve":
        return cmd_approve(path, flags.get("--by"))
    if command == "refine":
        return cmd_refine(path, flags.get("--note") or die('refine needs --note "<his note>"'))
    if command == "reject":
        return cmd_reject(path, flags.get("--reason") or die(f"reject needs --reason, one of: {' '.join(REASONS)}"),
                          flags.get("--note") or "")
    die(__doc__)

if __name__ == "__main__":
    main()
