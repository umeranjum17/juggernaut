"""show <ticket> [--json]: the workflow record of a ticket, then one line per step: stage, kind, row, open or closed,
the task id, and the last status verb of its lane (`no lane` before one starts). Reads only."""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import store  # noqa: E402
import wflib  # noqa: E402

RECORD = ("workflow", "workflow_name", "workflow_sha", "workflow_by", "workflow_quote", "workflow_note", "workflow_order",
          "workflow_angles", "workflow_subject", "workflow_at")


def main():
    p = argparse.ArgumentParser(prog="jg-workflow.sh show")
    p.add_argument("ticket")
    p.add_argument("--json", action="store_true")
    a = p.parse_args()
    store.home()
    row = store.read(a.ticket)
    if row is None:
        wflib.refuse(f"no ticket {a.ticket} in this home")
    meta = row.get("metadata") or {}
    if not meta.get("workflow"):
        wflib.refuse(f"{a.ticket} has no workflow")
    steps = [{"stage": int(r["metadata"]["wf_stage"]), "index": int(r["metadata"]["wf_index"]), "kind": r["metadata"]["wf_kind"],
              "arg": r["metadata"].get("wf_arg") or None, "row": r["id"], "state": "closed" if r.get("status") == "closed" else "open",
              "task": store.task_id(r["id"]), "lane": store.lane_verb(r["id"])} for r in store.steps(a.ticket)]
    record = {k: meta.get(k, "") for k in RECORD}
    if a.json:
        print(json.dumps({"ticket": a.ticket, "record": record, "steps": steps}))
        return
    by = record["workflow_by"] + (f' "{record["workflow_quote"]}"' if record["workflow_quote"] else "")
    print(f"workflow {record['workflow_sha']} on {a.ticket}: {record['workflow']}")
    print(f"name {record['workflow_name']}, by {by}, order {record['workflow_order']}, subject {record['workflow_subject'] or '-'}")
    for s in steps:
        kind = s["kind"] + (f"({s['arg']})" if s["arg"] else "")
        print(f"stage {s['stage']} {kind} {s['row']} {s['state']} task {s['task']} {s['lane']}")


wflib.run(main)
