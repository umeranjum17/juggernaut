"""parse <spec|name> [--by owner|main|lead] [--text]: the ordered stages of a spec or a name, as one JSON line
(--text: one line per stage). A refusal prints `refused: <rule>` on stderr, exits 2 and prints nothing else."""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wflib  # noqa: E402


def main():
    p = argparse.ArgumentParser(prog="jg-workflow.sh parse")
    p.add_argument("spec", help="a spec such as 'scout > owner > worker', or a name from the workflows files")
    p.add_argument("--by", default="main", choices=wflib.BY)
    p.add_argument("--text", action="store_true", help="one line per stage")
    a = p.parse_args()
    name, stages = wflib.parse(a.spec, a.by)
    if a.text:
        print("\n".join(wflib.stage_texts(stages)))
    else:
        print(json.dumps({"name": name, "spec": wflib.canonical(stages), "sha": wflib.sha(stages),
                          "stages": wflib.as_json(stages)}))


wflib.run(main)
