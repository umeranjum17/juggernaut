#!/usr/bin/env python3
"""run-rule.py - judge one red GitHub run of the behaviour suite under the verify's one rule (core/trunk-verify/reduce.py).

  run-rule.py judge --red <aggregate.json> --green <aggregate.json> [--open <open.json>] [--repo <git dir> --green-head <sha>
                    --red-head <sha>] [--grace N]

The two aggregates are the `jg-test-timing-aggregate` artifact of the red run and of the last green run (bin/jg-test-run.sh
--aggregate-json); a path that does not exist is a missing aggregate. This script only turns them into the reducer's inputs and
reads its verdict back; the rule itself (what is counted, carried or incomplete, and when a run is red) lives in reduce.py alone.

  - the last green run is the pin: a script that passed there and fails in the red run is a regression (counted); a script the green
    run does not hold is new; a script with no baseline at all (no green aggregate) is incomplete, never counted
  - --open lists [{"script", "item", "status"}]: a script an open fix item already names failed in an earlier red run, so it is carried
    (the same failure, matched to its item) and is never a new item
  - exit 124 and 137 are runner-bound timeouts and a gate skip is a skip: both are incomplete, never a failure
  - the introducing commit of a new failure is the newest commit between the two heads that touched the script, else the red head
    (the range is then named, never one commit guessed)

Prints one JSON object: status (green, graced, incomplete or red), restore (true only for red), missing (the aggregates that could
not be read), file (new failures and incomplete scripts, each with its class and introducing commit), matched (carried scripts with
the open item that owns each) and reasons.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TIMEOUT_EXITS = (124, 137)


def load_reducer():
    spec = importlib.util.spec_from_file_location("jg_reduce", os.path.join(HERE, "..", "trunk-verify", "reduce.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read_aggregate(path):
    """{script: {exit, skip}} from an aggregate file, or None when it cannot be read."""
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError, TypeError):
        return None
    scripts = doc.get("scripts")
    if not isinstance(scripts, list) or not scripts:
        return None
    return {s["path"]: {"exit": int(s.get("exit") or 0), "skip": bool(s.get("gate_skip"))} for s in scripts if s.get("path")}


def run_kind(row):
    if row is None:
        return "missing"
    if row["skip"]:
        return "skip"
    if row["exit"] == 0:
        return "pass"
    return "timeout" if row["exit"] in TIMEOUT_EXITS else "fail"


def introduced_in(repo, green_head, red_head, script):
    """The newest commit between the heads that touched the script, else the range, else the red head."""
    if not (repo and red_head):
        return red_head or "unknown"
    rng = f"{green_head}..{red_head}" if green_head else red_head
    out = subprocess.run(["git", "-C", repo, "log", "-1", "--format=%h", rng, "--", script], capture_output=True, text=True)
    if out.returncode == 0 and out.stdout.strip():
        return out.stdout.strip()
    return f"somewhere in {green_head[:12]}..{red_head[:12]}" if green_head else red_head[:12]


def judge(args, reducer):
    red, green = read_aggregate(args.red), read_aggregate(args.green)
    opened = {}
    if args.open:
        with open(args.open, encoding="utf-8") as fh:
            opened = {o["script"]: o for o in json.load(fh) if o.get("status") not in ("done", "closed")}
    manifest = sorted(set(red or {}) | set(green or {}))
    pin = {}
    for s in manifest:
        if s in opened:
            pin[s] = {"state": "fail"}  # the same failure an earlier red run already filed: carried
        elif green is None:
            pin[s] = {"state": "unknown"}
        else:
            pin[s] = {"state": "pass" if s in green and run_kind(green[s]) == "pass" else "absent" if s not in green else "unknown"}
    inputs = {"grace": args.grace, "aggregate_present": red is not None, "manifest": manifest, "pin": pin,
              "runs": {s: [{"kind": run_kind((red or {}).get(s))}] for s in manifest}}
    v = reducer.verdict(inputs)
    cls = v["class"]
    matched = [{"script": s, "item": opened[s]["item"], "class": cls[s]} for s in manifest if s in opened and cls[s] != "pass"]
    filed = [{"script": s, "class": cls[s], "commit": introduced_in(args.repo, args.green_head, args.red_head, s)}
             for s in manifest if cls[s] != "pass" and s not in opened]
    missing = [n for n, a in (("red aggregate", red), ("green aggregate", green)) if a is None]
    return {"status": v["status"], "restore": v["status"] == "red", "missing": missing, "file": filed, "matched": matched,
            "reasons": v["incomplete_reasons"]}


def main(argv):
    ap = argparse.ArgumentParser(prog="run-rule.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    j = sub.add_parser("judge")
    j.add_argument("--red", required=True)
    j.add_argument("--green", required=True)
    j.add_argument("--open")
    j.add_argument("--repo")
    j.add_argument("--green-head", default="")
    j.add_argument("--red-head", default="")
    j.add_argument("--grace", type=int, default=2)
    args = ap.parse_args(argv[1:])
    print(json.dumps(judge(args, load_reducer()), indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
