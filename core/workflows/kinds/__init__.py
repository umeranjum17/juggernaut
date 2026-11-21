"""kinds: what a workflow step kind does. A kind is one file, core/workflows/kinds/<kind>.py (a `-` in the name reads as `_`),
or one in $JG_WORKFLOW_KIND_DIR when that is set (the test hook). A kind module has two functions:

  start(home, step) -> ("started" | "waits" | "failed", why)   may be slow: it runs only inside the step's own job
  result(home, step) -> ("done" | "open" | "failed", why)      reads records only; the pass gives it 2 seconds

`step` is the step row as the store holds it. A kind that must call an outside command from `result` starts it with
`detach` and reads what it left behind on a later pass: the pass never waits on an outside command."""
import importlib.util
import os
import subprocess
import sys

DIR = os.path.dirname(os.path.abspath(__file__))


def data_dir(home):
    """data/workflows of the home: every record a step leaves (`<row>.started`, `<row>.start.rc`, a job's pid, rc and log).
    The folder is made by the first write."""
    return os.path.join(os.environ.get("JG_DATA_OVERRIDE") or os.path.join(home, "data"), "workflows")


def kind(name):
    """The module of a step kind, or None when there is none."""
    stem = name.replace("-", "_")
    path = os.path.join(os.environ.get("JG_WORKFLOW_KIND_DIR") or DIR, stem + ".py")
    if not stem.isidentifier() or stem == "__init__" or not os.path.isfile(path):
        return None
    spec = importlib.util.spec_from_file_location("jg_workflow_kind_" + stem, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def write(path, text):
    """Write a record whole or not at all."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def alive(pid):
    """Whether a process runs; one that ended and waits to be reaped does not."""
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rpartition(")")[2].split()[0] != "Z"
    except (OSError, IndexError):
        return True


def job_pid(home, row, name):
    """The pid `detach` recorded for the job, or None."""
    try:
        with open(os.path.join(data_dir(home), f"{row}.{name}.pid")) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def detach(home, row, name, argv):
    """Start an outside command in its own session and return at once, `setsid nohup` as bin/jg-recon-handoff.sh does, so
    a `timeout` around the pass cannot kill it. Output goes to data/workflows/<row>.<name>.log, the pid to <row>.<name>.pid
    and the exit code to <row>.<name>.rc when the command ends. Does nothing while that pid is alive. -> (started, pid)."""
    base = os.path.join(data_dir(home), f"{row}.{name}")
    old = job_pid(home, row, name)
    if old is not None and alive(old):
        return False, old
    os.makedirs(os.path.dirname(base), exist_ok=True)
    try:
        os.unlink(base + ".rc")
    except FileNotFoundError:
        pass
    with open(base + ".log", "ab") as log, open(os.devnull, "rb") as nothing:
        p = subprocess.Popen(["nohup", "sh", "-c", 'rc=$1; shift; "$@"; echo $? > "$rc"', "sh", base + ".rc"] + list(argv),
                             stdin=nothing, stdout=log, stderr=log, start_new_session=True, env=os.environ.copy())
    write(base + ".pid", f"{p.pid}\n")
    return True, p.pid
