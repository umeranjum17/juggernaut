"""pick <ticket> [--set]: the default workflow of a ticket by the `pick <test> <value>: <name>` lines of the workflows files,
first match wins; prints `<name>\\t<spec>\\t<rule>`. A ticket that already has a record prints it as `kept: named by <by>`
and nothing changes. With --set the pick goes on the ticket through `set` (--by lead in a Squad Lead home, else --by main,
and no --order, so `set` takes the ticket's own order or refuses). A rule that does not parse is refused, nothing is set.
Tests: title-tag <tag>, title-has <words>, kind <metadata.kind>, label <label>, any."""
import argparse
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import store  # noqa: E402
import wflib  # noqa: E402

LEADING_TAGS = re.compile(r"\s*(?:\[[^\]]*\]\s*)+")


def tags_of(row):
    """The ticket's tags: the board files a `[tag]` of the title as a label, and an unfiled one still leads the title."""
    m = LEADING_TAGS.match(row.get("title") or "")
    leading = re.findall(r"\[([^\]]*)\]", m.group(0)) if m else []
    return {str(t).strip().lower() for t in leading + list(row.get("labels") or [])}


def holds(test, row):
    """Whether the rule's test (`<test> <value>`) holds for the ticket row."""
    name, _, value = test.partition(" ")
    value = value.strip().lower()
    title = row.get("title") or ""
    if name == "any" and not value:
        return True
    if name == "title-tag" and value:
        return value.strip("[]") in tags_of(row)
    if name == "title-has" and value:
        return value in title.lower()
    if name == "kind" and value:
        return str((row.get("metadata") or {}).get("kind", "")).lower() == value
    if name == "label" and value:
        return value in [str(x).lower() for x in row.get("labels") or []]
    wflib.refuse(f"pick rule \"pick {test}\": a test is `title-tag <tag>`, `title-has <words>`, `kind <kind>`, `label <label>` or `any`")


def rules(c):
    """[(test, workflow, spec)] with every rule checked: its workflow must parse, so a broken line stops the pick."""
    out = []
    for test, value in c.picks:
        try:
            stages = wflib.parse(value, "main", c)[1]
        except wflib.Refused as e:
            raise wflib.Refused(f'pick rule "pick {test}: {value}": {e}')
        out.append((test, value, wflib.canonical(stages)))
    return out


def main():
    p = argparse.ArgumentParser(prog="jg-workflow.sh pick")
    p.add_argument("ticket")
    p.add_argument("--set", action="store_true", help="put the pick on the ticket")
    a = p.parse_args()
    store.home()
    row = store.read(a.ticket)
    if row is None:
        wflib.refuse(f"no ticket {a.ticket} in this home")
    meta = row.get("metadata") or {}
    if meta.get("workflow"):
        print(f"{meta.get('workflow_name', '')}\t{meta['workflow']}\tkept: named by {meta.get('workflow_by', 'unknown')}")
        return 0
    chosen = next((r for r in rules(wflib.load()) if holds(r[0], row)), None)
    if chosen is None:
        wflib.refuse(f"no pick rule fits {a.ticket}: add a `pick any: <name>` line to {wflib.HOME_FILE}")
    test, value, spec = chosen
    made = ""
    if a.set:
        root = wflib.roots()[0]
        by = "lead" if os.path.exists(os.path.join(store.home(), ".jg-squad-lead-home")) else "main"
        p = subprocess.run([os.path.join(root, "bin", "jg-workflow.sh"), "set", a.ticket, value, "--by", by],
                           capture_output=True, text=True)
        if p.returncode != 0:
            sys.stderr.write(p.stderr)
            return 2
        made = p.stdout
    print(f"{value}\t{spec}\t{test}")
    print(made, end="")


wflib.run(main)
