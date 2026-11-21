"""set <ticket> <spec|name> --by owner|main|lead [--quote <words>] [--note <chat-note-id>] [--order <ref>]
[--angles <a,b,c>] [--project <name>] [--subject <words>]: put a workflow on a ticket. The ticket's own metadata holds the
spec and who chose it, and one child row per step holds the rest, each stage blocked by every row of the stage before.
`set <ticket> --subject <words>` changes only the subject, at any time. Every rule is checked before the first write."""
import argparse
import datetime
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import store  # noqa: E402
import wflib  # noqa: E402

REF = re.compile(r"[A-Za-z0-9._:-]+")
ORDER_LINE = re.compile(r"Owner order:\s*(" + REF.pattern + ")")
MAIN_ORDER = re.compile(r"\bMain\d+\b")
QUOTE_MAX, SUBJECT_MAX = 200, 8


def order_of(row, given):
    """The owner order the steps serve: the --order flag, else the first order line of the ticket's body, else the ticket itself when it is an ask."""
    if given:
        ref = given
    else:
        ref = None
        for line in (row.get("description") or "").splitlines():
            m = ORDER_LINE.search(line) or MAIN_ORDER.search(line)
            if m:
                ref = (m.group(1) if m.re is ORDER_LINE else m.group(0)).rstrip(".")
                break
        if ref is None and ("captain-ask" in (row.get("labels") or []) or row.get("title", "").startswith("[captain-ask]")):
            ref = row["id"]
    if not ref:
        wflib.refuse("no owner order (pass --order MainNNN)")
    if not REF.fullmatch(ref):
        wflib.refuse(f"'{ref}' is not an order reference (letters, digits and . _ : - only)")
    return ref


def project_of(row, given):
    if given:
        return given
    for label in row.get("labels") or []:
        if label.startswith("project:"):
            return label[len("project:"):]
    wflib.refuse(f"{row['id']} names no project (pass --project)")


def check_subject(subject):
    if subject is not None and not 1 <= len(subject.split()) <= SUBJECT_MAX:
        wflib.refuse(f"the subject is 1 to {SUBJECT_MAX} plain words, not {len(subject.split())}")


def units(stages):
    """[(stage number, [(index, kind, arg)])]: one unit per step, `kind*N` is N units; the index counts across the stage."""
    out = []
    for s, row in enumerate(stages, 1):
        flat = [(k, a) for k, a, n in row for _ in range(n)]
        out.append((s, [(i, k, a) for i, (k, a) in enumerate(flat, 1)]))
    return out


def gate_stage(plan, s):
    """The stage whose owner row gates a build in stage s: the latest owner stage before it, when a report stage came earlier."""
    if not any(k in wflib.REPORTS for t, row in plan if t < s for _, k, _ in row):
        return None
    return max((t for t, row in plan if t < s and any(k == "owner" for _, k, _ in row)), default=None)


def body_of(ticket, order, sha, s, i, total, kind, arg, gate):
    label = f"{kind}({arg})" if arg else kind
    lines = [
        "## Captain",
        f"The owner chose workflow {sha} for {ticket} ({order}); this row is its step {i} of {total} in stage {s}: {label}.",
        "## Ask",
        f"Run the {label} step of workflow {sha} on {ticket}.",
        "## Why",
        "A workflow is a set of rows, so each step starts by itself once the stage before it is finished.",
        "## Done when",
        f"The {label} step has its own result on record and this row is closed.",
        "## Acceptance Criteria",
        f"The step's result is on record under {ticket}.",
        f"parent: {ticket}",
        f"Owner order: {order}.",
        f"Workflow: stage {s} step {i} kind {label}",
    ]
    if gate:
        lines += ["born-from: recon", f"plan-approved-on: {gate}"]
    return "\n".join(lines)


def set_subject(ticket, row, subject):
    check_subject(subject)
    store.set_meta(ticket, {"workflow_subject": subject})
    print(f"subject of {ticket}: {subject}")


def main():
    p = argparse.ArgumentParser(prog="jg-workflow.sh set")
    p.add_argument("ticket")
    p.add_argument("spec", nargs="?", help="a spec or a name; with none, only --subject changes")
    p.add_argument("--by", default="main", choices=wflib.BY)
    p.add_argument("--quote", help="the owner's words, 200 characters at most (needed with --by owner)")
    p.add_argument("--note", help="the chat note that holds the owner's words (needed with --by owner)")
    p.add_argument("--order", help="the owner order the steps serve, e.g. Main42707")
    p.add_argument("--angles", default="", help="the Recon angles, comma separated")
    p.add_argument("--project", help="the project the step rows belong to (default: the ticket's)")
    p.add_argument("--subject", help="the plain words the owner's plan card names, 8 words at most")
    a = p.parse_args()
    store.home()
    row = store.read(a.ticket)
    if row is None:
        wflib.refuse(f"no ticket {a.ticket} in this home")
    meta = row.get("metadata") or {}
    if a.spec is None:
        if a.subject is None:
            wflib.refuse("nothing to set: give a spec or a name, or --subject")
        return set_subject(a.ticket, row, a.subject)

    name, stages = wflib.parse(a.spec, a.by)
    sha = wflib.sha(stages)
    check_subject(a.subject)
    if a.by == "owner":
        if not a.quote or not a.note:
            wflib.refuse("--by owner needs --quote <his words> and --note <chat note id>")
        if len(a.quote) > QUOTE_MAX:
            wflib.refuse(f"the quote is {len(a.quote)} characters; the limit is {QUOTE_MAX}")
    if meta.get("workflow_by") == "owner" and a.by != "owner":
        wflib.refuse(f'the owner named this workflow: "{meta.get("workflow_quote", "")}"')
    order = order_of(row, a.order)
    project = project_of(row, a.project)

    live = store.steps(a.ticket)
    old = [r for r in live if r["metadata"].get("wf_sha") != sha]
    began = [f"{r['id']} ({store.started(r['id'])})" for r in old if store.started(r["id"])]
    if began:
        wflib.refuse(f"a step has started, so the workflow of {a.ticket} stays: {', '.join(began)}")

    for r in old:
        store.set_meta(r["id"], {"wf_superseded": sha})
        store.done(r["id"], f"superseded by workflow {sha}")
    have = {(r["metadata"]["wf_stage"], r["metadata"]["wf_index"], r["metadata"]["wf_kind"]): r["id"]
            for r in live if r["metadata"].get("wf_sha") == sha}

    plan = units(stages)
    rows, new, before = {}, 0, []  # rows: (stage, index) -> row id; before: the rows of the stage before
    total = sum(len(u) for _, u in plan)
    for s, stage in plan:
        made = []
        for i, kind, arg in stage:
            gs = gate_stage(plan, s) if kind == "worker" else None
            gate = rows[(gs, 1)] if gs else None
            key = (str(s), str(i), kind)
            if key in have:
                made.append(have[key])
                rows[(s, i)] = have[key]
                continue
            rid = store.add(a.ticket, f"Workflow step {s}: {kind} {i} of {len(stage)}", project,
                            body_of(a.ticket, order, sha, s, i, len(stage), kind, arg, gate), before)
            fields = {"wf_parent": a.ticket, "wf_stage": s, "wf_index": i, "wf_kind": kind, "wf_arg": arg or "", "wf_sha": sha}
            if gate:
                fields["wf_gate"] = gate
            store.set_meta(rid, fields)
            made.append(rid)
            rows[(s, i)] = rid
            new += 1
        before = made

    store.set_meta(a.ticket, {
        "workflow": wflib.canonical(stages), "workflow_name": name, "workflow_sha": sha, "workflow_by": a.by,
        "workflow_quote": (a.quote or "") if a.by == "owner" else "", "workflow_note": (a.note or "") if a.by == "owner" else "",
        "workflow_order": order, "workflow_angles": a.angles,
        "workflow_subject": a.subject if a.subject is not None else meta.get("workflow_subject", ""),
        "workflow_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    print(f"workflow {sha} on {a.ticket}: {total} steps ({new} new)")


wflib.run(main)
