"""Record a board answer for its owner step. Exit 3 lets board intake handle other cards."""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kinds  # noqa: E402
from kinds import owner  # noqa: E402
import steplib  # noqa: E402
import store  # noqa: E402
import wflib  # noqa: E402


def approve(home, key, rows, decision, path):
    parent = subprocess.run(["bash", "-c", '''
        . "$1/jg-squad-lead-parent-lib.sh"
        jg_squad_lead_parent_record_parse "$(jg_compat_parent_marker "$JG_HOME")" || exit 0
        [ "$JG_SQUAD_LEAD_PARENT_ROUTE" != local ] || printf '%s\n' "$JG_SQUAD_LEAD_PARENT_HOME"
    ''', "_", owner.BIN], capture_output=True, text=True, check=True).stdout.strip()
    kinds.write(str(path), decision + "\n")
    for row in rows:
        answer = owner._hold(home, "answer", row, "--decision-file", path, "--release", "--card", key, signer=parent)
        if answer.returncode != 0:
            raise steplib.Failed((answer.stderr or answer.stdout).strip() or f"could not release {row}")


def muster_answer(key, answer, label):
    matched = re.fullmatch(r"muster-([\w.-]+)-r\d+q\d+-v\d+", key)
    if not matched:
        return 3
    row = store.read(matched[1])
    if not row or (row.get("metadata") or {}).get("wf_kind") != "muster":
        return 3
    if re.match(r"^\s*(?:taken|default|agent)\b", label, re.I):
        return 0
    steplib._run(store.home(), [owner.BIN / "jg-muster.sh", "answer", row["id"], "--card", key,
                                "--value" if answer in ("a", "b", "c", "d") else "--words", answer],
                 "Muster could not record the board answer")
    return 0


def main():
    parser = argparse.ArgumentParser(prog="jg-workflow.sh answer")
    parser.add_argument("key")
    parser.add_argument("--answer", required=True)
    parser.add_argument("--at", required=True)
    parser.add_argument("--label", default="")
    parser.add_argument("--note", default="")
    a = parser.parse_args()
    if a.key in (".", "..") or not re.fullmatch(r"[A-Za-z0-9._-]+", a.key):
        raise steplib.Failed("invalid card key")
    try:
        ticket, row, _, _, _, values, held = (owner.markers() / a.key).read_text().rstrip("\n").split("\t")
        yes, no = values.split(",")
    except FileNotFoundError:
        return muster_answer(a.key, a.answer, a.label)
    if re.match(r"^\s*(?:taken|default|agent)\b", a.label, re.I):
        raise steplib.Failed("only the owner's answer can approve this plan")
    if a.answer not in (yes, no) or not a.at or len(a.at.split()) != 1 or a.at.strip() != a.at:
        raise steplib.Failed(f"invalid answer for {a.key}")

    home = store.home()
    path = Path(kinds.data_dir(home)) / f"{row}.answer"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix(".answer.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        records = path.read_text().splitlines() if path.exists() else []
        if any(fields[1] == a.at and fields[3] == a.key
               for line in records if len(fields := line.split("\t", 3)) == 4):
            return 0
        event = hashlib.sha256(f"{a.key}\n{a.at}".encode()).hexdigest()[:20]
        label = " ".join(a.label.split())
        if a.answer == yes:
            approve(home, a.key, held.split(","), f"Approved on {a.key} at {a.at}.\n{label}\n{a.note}",
                    path.with_suffix(f".{event}.decision"))
            rows = {r for ids in owner.cards_for(row).values() for r in ids}
            store.set_meta(row, {"wf_approved_row": ",".join(sorted(rows))})
        else:
            steplib._run(home, [owner.BIN / "jg-inbox.sh", "note", "--request-id", f"wf-answer-{event}", "--",
                               f"Plan approval for {ticket} is still open. The owner's words: {a.note or label or a.answer}"],
                         "could not record the owner's words")
        records.append(f"{'a' if a.answer == yes else 'b'}\t{a.at}\t{label}\t{a.key}")
        kinds.write(str(path), "\n".join(records) + "\n")
    check = Path(store.state_dir()) / "auto-dispatch.check.sh"
    if a.answer == yes and check.is_file():
        kinds.detach(home, row, "answer-kick", [str(check)])
    return 0


try:
    sys.exit(main())
except (OSError, ValueError, steplib.Failed, wflib.Refused, subprocess.SubprocessError) as e:
    print(f"workflow answer: {e}", file=sys.stderr)
    sys.exit(1)
