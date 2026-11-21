"""advance <home> [--close-only] [--dry-run]: one quick pass over every open ticket that carries a workflow. It closes each
finished step and starts each ready one as a detached job, and it never waits for an outside command.

  close   a step whose start record says rc 0 and whose kind's `result` is done: `bin/jg-backlog.sh done <row>`.
          Each `result` has 2 seconds; over that the step stays open and the pass logs `slow`.
  failed  a start record with rc not 0, a start job gone with no record, a result of `failed`, or a kind with no handler: the step stays open, so
          the stages after it stay blocked, and one `workflow-step-failed` alert is raised for it.
  start   a step whose blockers are all closed and that has no data/workflows/<row>.started: write `.started`, launch
          `bin/jg-workflow.sh step-start <home> <row>` with `detach`, print `started <row> (<kind>)`.

The pass is safe to run twice at once (a second run leaves a mark and the first makes one more pass), to be killed (the kernel
frees the lock) and to meet a slow step (its start runs in its own job). `--dry-run` prints and writes nothing."""
import argparse
import fcntl
import json
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kinds  # noqa: E402
import store  # noqa: E402
import wflib  # noqa: E402

RESULT_BUDGET = 2  # seconds one kind's `result` may take
ALERT = os.environ.get("JG_WORKFLOW_ALERT") or os.path.join(store.ROOT, "bin", "jg-alert.sh")


class Slow(Exception):
    pass


def _alarm(signum, frame):
    raise Slow()


def tickets():
    """The open tickets that carry a workflow."""
    out = store._run(store.BD + ["list", "--limit", "0", "--json"], "cannot list the tickets")
    return [t["id"] for t in json.loads(out or "[]") if (t.get("metadata") or {}).get("workflow")]


def blockers(row):
    return [d["depends_on_id"] for d in row.get("dependencies") or [] if d.get("type") == "blocks"]


def read_start(home, row):
    """(rc, status, why) of the step's start record, or None when the job has not written one."""
    try:
        with open(os.path.join(kinds.data_dir(home), f"{row}.start.rc")) as f:
            rc, status, why = (f.read().strip().split(None, 2) + ["", ""])[:3]
        return int(rc), status, why
    except (OSError, ValueError):
        return None


class Pass:
    def __init__(self, home, close_only, dry):
        self.home, self.close_only, self.dry = home, close_only, dry
        self.data = kinds.data_dir(home)
        self.said = set()
        self.status = {}  # row id -> status, as read and as this pass changes it

    def path(self, row, suffix):
        return os.path.join(self.data, f"{row}.{suffix}")

    def say(self, text):
        print(text, flush=True)

    def result(self, module, step, kind):
        """The kind's result within its budget; a slow or broken one leaves the step open."""
        old = signal.signal(signal.SIGALRM, _alarm)
        signal.alarm(RESULT_BUDGET)
        try:
            return module.result(self.home, step)
        except Slow:
            self.say(f"slow {step['id']} ({kind})")
            return "open", "slow"
        except Exception as e:  # noqa: BLE001 - one kind's fault never stops the pass
            return "failed", f"{type(e).__name__}: {e}"
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, old)

    def fail(self, ticket, row, kind, why):
        """One alert per failed step: the mark is written only when the alert was raised."""
        mark = self.path(row, "failed")
        if os.path.exists(mark):
            return
        if self.dry:
            return self.say(f"would raise workflow-step-failed {row} ({kind}): {why}")
        env = dict(os.environ, JG_STATE_OVERRIDE=store.state_dir(), JG_HOME=self.home)
        p = subprocess.run([ALERT, "raise", "workflow-step-failed", row, "--note", f"{ticket}: {why}", "--deliver"],
                           env=env, capture_output=True, text=True)
        self.say(f"failed {row} ({kind}): {why}")
        if p.returncode != 0:
            print(f"alert refused for {row}: {(p.stdout + p.stderr).strip()}", file=sys.stderr)
            return
        kinds.write(mark, why + "\n")

    def close(self, row, kind, why):
        if self.dry:
            return self.say(f"would close {row} ({kind}): {why}")
        try:
            store.done(row, why)
        except wflib.Refused as e:
            return print(f"{row}: {e}", file=sys.stderr)
        self.status[row] = "closed"
        self.say(f"closed {row} ({kind}): {why}")

    def start(self, row, kind):
        if self.dry:
            return self.say(f"would start {row} ({kind})")
        started = self.path(row, "started")
        kinds.write(started, f"{int(time.time())} {kind}\n")
        _, pid = kinds.detach(self.home, row, "step-start", [os.path.join(store.ROOT, "bin", "jg-workflow.sh"), "step-start", self.home, row])
        kinds.write(started, f"{int(time.time())} {kind} {pid}\n")
        self.say(f"started {row} ({kind})")

    def ticket(self, ticket):
        rows = store.steps(ticket)
        for r in rows:
            self.status[r["id"]] = r["status"]
        for r in rows:
            row, kind = r["id"], r["metadata"]["wf_kind"]
            if self.status[row] == "closed":
                continue
            rec = read_start(self.home, row)
            if rec is not None and rec[0] != 0:
                self.fail(ticket, row, kind, rec[2] or "the start failed")
                continue
            if rec is None and os.path.exists(self.path(row, "started")):
                pid = kinds.job_pid(self.home, row, "step-start")
                if pid is None or not kinds.alive(pid):
                    self.fail(ticket, row, kind, "the start job ended before it wrote its record")
                continue
            if rec is None:
                continue
            module = self.module(kind)
            if module is None:
                continue
            state, why = self.result(module, r, kind)
            if state == "done":
                self.close(row, kind, why)
            elif state == "failed":
                self.fail(ticket, row, kind, why)
        if self.close_only:
            return
        for r in rows:
            row, kind = r["id"], r["metadata"]["wf_kind"]
            if self.status[row] == "closed" or os.path.exists(self.path(row, "started")):
                continue
            if any(self.blocker_open(b) for b in blockers(r)):
                continue
            if self.module(kind) is None:
                self.fail(ticket, row, kind, f"no kind {kind}: the step has no handler, so nothing can start it")
                continue
            self.start(row, kind)

    def blocker_open(self, row):
        if row not in self.status:
            held = store.read(row)
            self.status[row] = held["status"] if held else "closed"
        return self.status[row] != "closed"

    def module(self, kind):
        module = kinds.kind(kind)
        if module is None and kind not in self.said:
            self.said.add(kind)
            self.say(f"no kind {kind}")
        return module


def take(path):
    """The pass lock: a flock on an open descriptor, which the kernel frees when the process dies. None when another pass holds it."""
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


def main():
    p = argparse.ArgumentParser(prog="jg-workflow.sh advance")
    p.add_argument("home")
    p.add_argument("--close-only", action="store_true", help="close finished steps; start none")
    p.add_argument("--dry-run", action="store_true", help="print what would happen and write nothing")
    a = p.parse_args()
    os.environ["JG_HOME"] = a.home
    state = store.state_dir()
    again = os.path.join(state, ".workflow-advance.again")
    work = Pass(a.home, a.close_only, a.dry_run)
    if a.dry_run:
        for t in tickets():
            work.ticket(t)
        return 0
    os.makedirs(state, exist_ok=True)
    fd = take(os.path.join(state, ".workflow-advance.lock"))
    if fd is None:
        open(again, "a").close()
        return 0
    while fd is not None:
        while True:  # a run that met the lock left the mark: one more pass after it
            if os.path.exists(again):
                os.unlink(again)
            for t in tickets():
                work.ticket(t)
            if not os.path.exists(again):
                break
        os.close(fd)
        fd = take(os.path.join(state, ".workflow-advance.lock")) if os.path.exists(again) else None
    return 0


wflib.run(main)
