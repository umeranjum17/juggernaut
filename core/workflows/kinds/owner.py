"""owner: the owner's yes to a plan. `start` holds the row for the captain through bin/jg-captain-hold.sh, the one place a question
for him is raised; the step is done when that hold's phase says his words answered it. The build rows rest on this row's yes."""
import os
import subprocess

import steplib
import store


def _hold(home, *argv):
    tool = os.environ.get("JG_WORKFLOW_HOLD") or os.path.join(store.ROOT, "bin", "jg-captain-hold.sh")
    return subprocess.run([tool, *argv], env={**os.environ, "JG_HOME": home}, capture_output=True, text=True)


def start(home, step):
    ticket = store.read(step["metadata"]["wf_parent"])
    p = _hold(home, "hold", step["id"], "--reason", f"approve the plan of {ticket['id']}: {ticket['title']}"[:200])
    if p.returncode != 0:
        raise steplib.Failed("the owner's question was not raised: " + ((p.stdout + p.stderr).strip().splitlines() or ["?"])[-1][:200])
    return "waits", "the owner's yes is asked for"


def result(home, step):
    p = _hold(home, "phase", step["id"])
    if p.returncode != 0:
        return "failed", "the owner's answer could not be read"
    return ("done", "the owner answered") if p.stdout.strip() in ("answered", "closed") else ("open", "waiting for the owner")
