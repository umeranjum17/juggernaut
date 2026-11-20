"""step-start <home> <row>: the job `advance` launches detached for one step. It calls the step kind's `start`, which may take
minutes, writes data/workflows/<row>.start.rc (`<rc> <status> <why>`: rc 0 for started and waits, 1 for failed), and after a
`started` runs the home's dispatch check detached, so dispatch starts the approved row at once. The pass never waits for it."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kinds  # noqa: E402
import store  # noqa: E402
import wflib  # noqa: E402


def main():
    if len(sys.argv) != 3:
        wflib.refuse("usage: jg-workflow.sh step-start <home> <row>")
    home, row = sys.argv[1], sys.argv[2]
    os.environ["JG_HOME"] = home
    step = store.read(row)
    if step is None:
        wflib.refuse(f"no step row {row} in {home}")
    name = (step.get("metadata") or {}).get("wf_kind", "")
    module = kinds.kind(name)
    if module is None:
        status, why = "failed", f"no kind {name}"
    else:
        try:
            status, why = module.start(home, step)
        except Exception as e:  # noqa: BLE001 - the record must say what broke, whatever it was
            status, why = "failed", f"{type(e).__name__}: {e}"
    if status not in ("started", "waits", "failed"):
        status, why = "failed", f"the {name} kind's start returned '{status}'"
    why = " ".join(str(why).split())
    kinds.write(os.path.join(kinds.data_dir(home), f"{row}.start.rc"), f"{0 if status != 'failed' else 1} {status} {why}\n")
    if status == "started":
        check = os.path.join(store.state_dir(), "auto-dispatch.check.sh")
        if os.path.exists(check):
            kinds.detach(home, row, "kick", [check])
    return 0 if status != "failed" else 1


wflib.run(main)
