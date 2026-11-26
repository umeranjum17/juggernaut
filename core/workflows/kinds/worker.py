"""A worker starts a lane and closes on its landing or merged PR."""
import os
import subprocess
import sys
import time
from urllib.parse import urlparse

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import kinds
import steplib
import store


def start(home, step):
    steplib.brief(home, step, scout=False)
    steplib.approve(home, step, "worker")
    return "started", "the brief is written and the start is approved"


def poll(url, path):
    answer = os.environ.get("JG_WORKFLOW_PR_MERGED")
    if answer is None:
        parts = urlparse(url)
        fields = parts.path.strip("/").split("/")
        if parts.scheme != "https" or parts.hostname != "github.com" or len(fields) != 4 or fields[2] != "pull" or not fields[3].isdigit():
            return
        try:
            p = subprocess.run(["gh-axi", "pr", "view", fields[3], "--repo", "/".join(fields[:2])],
                               capture_output=True, text=True, timeout=45, check=True)
            answer = next((line.split(":", 1)[1].strip().lower() for line in p.stdout.splitlines()
                           if line.startswith("state:")), "unknown")
        except (OSError, subprocess.SubprocessError):
            return
    kinds.write(path, url + "\n" + answer.lower() + "\n")


def result(home, step):
    row = step["id"]
    task = store.task_id(row)
    if step.get("status") == "closed":
        return "done", "the row is closed"
    try:
        with open(os.path.join(steplib.data_dir(home), "trunk-landings.tsv")) as f:
            if any(line.split("\t", 1)[0] == task for line in f):
                return "done", "the lane landed on the trunk"
    except FileNotFoundError:
        pass
    try:
        with open(os.path.join(store.state_dir(), task + ".status")) as f:
            lines = [line for line in f if line.strip()]
        verb = lines[-1].split(None, 1)[0].rstrip(":") if lines else ""
    except OSError:
        verb = ""
    if verb == "failed":
        return "failed", "the lane ended failed"
    if verb == "done":
        try:
            with open(os.path.join(store.state_dir(), task + ".meta")) as f:
                url = next((line.strip()[3:] for line in f if line.startswith("pr=")), "")
        except OSError:
            url = ""
        if url:
            base = os.path.join(kinds.data_dir(home), row + ".pr")
            try:
                with open(base) as f:
                    cached = f.read().splitlines()
                if cached[:2] == [url, "merged"]:
                    return "done", "the PR merged"
            except OSError:
                pass
            try:
                age = time.time() - os.stat(base + ".pid").st_mtime
            except FileNotFoundError:
                age = 60
            if age >= 60:
                kinds.detach(home, row, "pr", [sys.executable, __file__, "--poll", url, base])
    return "open", "the lane has not landed"


if __name__ == "__main__" and len(sys.argv) == 4 and sys.argv[1] == "--poll":
    poll(sys.argv[2], sys.argv[3])
