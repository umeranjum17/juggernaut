"""rounds: a deep Recon's critic loop runs itself. `bin/jg-workflow.sh rounds <researcher task> <row>` runs one pass and prints
`<accepted|open|failed>: <why>`; the kinds import `rounds(home, researcher, row)` and get `(state, why)`.

The record is bin/jg-recon-handoff.sh (phase, assignee, show) and data/<researcher>/critic.md; every move is tied to the report hash, and the
hashes a pass has acted on are kept in data/workflows/<row>.rounds (critiqued drafts told to the researcher), .sent (drafts told to the critic)
and .revised (revise moves made for the researcher). A pass tells a lane at most once per hash: it writes the hash, then makes one detached
call whose output goes to data/workflows/<row>.rounds.log. Tests replace the three tools with $JG_WORKFLOW_SEND, $JG_WORKFLOW_CONTROL and
$JG_WORKFLOW_CREW_STATE."""
import hashlib
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wflib  # noqa: E402

MAX_ROUNDS = 3  # critic rounds that found gaps; a fourth critiqued draft fails the step
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROUND = re.compile(r"^Round (\d+): new gaps (\d+) report ([0-9a-f]{64})$")


def _tool(env, name):
    return os.environ.get(env) or os.path.join(ROOT, "bin", name)


def _out(home, *argv):
    p = subprocess.run(argv, env={**os.environ, "JG_HOME": home}, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def _handoff(home, *argv):
    return _out(home, os.path.join(ROOT, "bin", "jg-recon-handoff.sh"), *argv)


def _read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def _marks(path):
    return [x for x in _read(path).split() if x]


def _live(home, task):
    """True when an agent is in the task's lane (`source: pane`)."""
    _, out, _ = _out(home, _tool("JG_WORKFLOW_CREW_STATE", "jg-crew-state.sh"), task)
    return "source: pane" in out


def _tell(home, wdir, row, task, words, store_serves):
    """One detached call that reaches `task`: a send to a live lane, else a relaunch carrying the words as its note."""
    live = _live(home, task)
    if live and store_serves:
        return
    argv = [_tool("JG_WORKFLOW_SEND", "jg-send.sh"), task, words] if live else [
        _tool("JG_WORKFLOW_CONTROL", "jg-control.sh"), task, "relaunch", "--note", words]
    with open(os.path.join(wdir, row + ".rounds.log"), "ab") as log:
        subprocess.Popen(argv, env={**os.environ, "JG_HOME": home}, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                         start_new_session=True)


def _mark(wdir, row, kind, value):
    """Record `value` under data/workflows/<row>.<kind>; False when it was already there."""
    path = os.path.join(wdir, f"{row}.{kind}")
    if value in _marks(path):
        return False
    with open(path, "a") as f:
        f.write(value + "\n")
    return True


def _log(wdir, row, text):
    with open(os.path.join(wdir, row + ".rounds.log"), "a") as f:
        f.write(text + "\n")


def _revised_unreported(home, researcher, rdir, critiqued):
    """The report hash when the researcher changed report.md and wrote a `done` line, else empty."""
    current = hashlib.sha256(_read(os.path.join(rdir, "report.md")).encode()).hexdigest()
    status = _read(os.path.join(home, "state", researcher + ".status")).strip().splitlines()
    return current if current != critiqued and status and status[-1].startswith("done") else ""


def rounds(home, researcher, row):
    data = os.environ.get("JG_DATA_OVERRIDE") or os.path.join(home, "data")
    store = os.path.exists(os.path.join(home, "config", "item-store"))
    wdir = os.path.join(data, "workflows")
    os.makedirs(wdir, exist_ok=True)
    rc, phase, err = _handoff(home, "phase", researcher)
    if rc:
        return "open", err or f"no handoff record for {researcher}"
    if phase == "accepted":
        return "accepted", "accepted"
    rdir = os.path.join(data, researcher)

    if phase == "critiqued":
        verdicts = [m.groups() for m in map(ROUND.match, _read(os.path.join(rdir, "critic.md")).splitlines()) if m]
        if not verdicts or int(verdicts[-1][1]) == 0:
            return "open", "the verdict has no gaps to act on"
        n, k, critiqued = int(verdicts[-1][0]), int(verdicts[-1][1]), verdicts[-1][2]
        revised = _revised_unreported(home, researcher, rdir, critiqued)
        if critiqued not in _marks(os.path.join(wdir, row + ".rounds")):
            if len(_marks(os.path.join(wdir, row + ".rounds"))) >= MAX_ROUNDS:
                return "failed", "three critic rounds and gaps remain"
            _mark(wdir, row, "rounds", critiqued)
            if not revised:
                _tell(home, wdir, row, researcher, f"Critic round {n} is in data/{researcher}/critic.md: {k} gaps. Revise the "
                      f"report and plan, run bin/jg-recon-handoff.sh revise {researcher}, and report the next draft ready.", False)
                return "open", f"round {n}: the researcher is told its {k} gaps"
        # The researcher revised and reported without the revise move: record it once per report hash.
        if revised and _mark(wdir, row, "revised", revised):
            rc, out, err = _handoff(home, "revise", researcher)
            if rc:
                _log(wdir, row, f"revise refused: {err or out}")
                return "open", "revise refused: " + (err or out)
        _, phase, _ = _handoff(home, "phase", researcher)

    if phase == "drafted":
        _, show, _ = _handoff(home, "show", researcher)
        moves = [line.split("\t") for line in show.splitlines() if line.count("\t") >= 5]
        critic = next((m[4] for m in reversed(moves) if m[1] == "assign"), "")  # a revise retires the assignment, the ticket stays
        n = sum(m[1] in ("draft", "revise") for m in moves)
        if critic and _mark(wdir, row, "sent", moves[-1][3]):
            _tell(home, wdir, row, critic, f"Draft {n} of {researcher} is ready at data/{researcher}/report.md: read it and "
                  "record your verdict with bin/jg-recon-handoff.sh verdict.", store)
            return "open", f"draft {n} is with {critic}"
    return "open", f"phase {phase}"


def main():
    if len(sys.argv) != 3:
        wflib.refuse("usage: jg-workflow.sh rounds <researcher task> <row>")
    state, why = rounds(os.environ.get("JG_HOME") or wflib.roots()[0], sys.argv[1], sys.argv[2])
    print(f"{state}: {why}")
    return 1 if state == "failed" else 0


if __name__ == "__main__":
    wflib.run(main)
