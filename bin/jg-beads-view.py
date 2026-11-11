#!/usr/bin/env python3
"""jg-beads-view.py - render bd rows in the read shape the backlog prints.

Usage: jg-beads.sh list --all --limit 0 --json | jg-beads-view.py <list|ready|show|view|markdown|links> [args...]

Reads stdin only, for bin/jg-backlog-lib.sh's jg_backlog_beads_read, and never starts bd.
Beads answers ready and blocked: when JG_BEADS_READY names a file holding `bd ready --json`, ready prints exactly those rows in bd's order,
and when JG_BEADS_BLOCKED names `bd blocked --json`, the blocked and blocked_by fields and list --blocked read it;
with neither, the answer is worked out from the rows' blocks edges, which is how a write answers.
Ours on top of bd's answer: a public-followup row is delivery work, so ready leaves it to its own count.
bin/jg-beads-write.py imports it, so a write answers in the same shape.
The links verb is not a backlog read: it prints the ids linked to one row, for bin/jg-captain-hold.sh's blocking gate.
bd stamps UTC and the backlog the local day, so created and closed read as the local day.
A held row is status on_hold, blocked or deferred, and reads as queued, or in flight while it has an assignee;
its fields stay readable on a closed row and on a row whose date has passed.
A dated hold is status deferred: bd ready wakes a past-date row to open and clears defer_until, and until that first
bd ready the row still reads as no longer held, so a due row reads the same on both sides of the wake;
kind is metadata.kind, else captain for issue_type decision, else issue_type;
parent is the parent-child edge target (upkeep by label) and item metadata.task, else metadata.legacy_item, both only through --fields;
show takes a row's id or the name it answers to: the task id its ticket was spawned under (metadata.task) or, after a migration, the slug or feed id it had before (metadata legacy_item, legacy_id, legacy_twin);
repo is the project:<repo> label; links are external_ref, metadata.prs and metadata.reports.
markdown prints the store in the backlog file's layout, for readers of that file's lines: ids are item, hold reasons encoded.
Refusals print the backlog's error lines on stdout: exit 2 for a bad flag, exit 1 for an unknown id.
"""
import base64
import datetime
import json
import os
import re
import sys

STATE = {"closed": "done"}
HELD = {"on_hold", "blocked", "deferred"}
CORE = {"decision": "captain"}
ROW = ["id", "state", "kind", "repo", "title"]
SHOW = ["id", "title", "state", "blocked", "blocked_by", "held", "hold_reason", "hold_kind", "hold_until",
        "kind", "repo", "priority", "created", "closed", "deps", "links", "body"]
EXTRA = sorted(set(SHOW) - set(ROW)) + ["parent", "item"]
CLIP = {"title": 80, "body": 500}
STATES = ["queued", "in_flight", "done", "held"]
PLAIN_NUMBER = re.compile(r"-?\d+(\.\d+)?([eE][+-]?\d+)?\Z")
MUST_QUOTE = re.compile(r'[,:"\\\[\]{}\x00-\x1f]')
ESCAPES = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\r": "\\r", "\t": "\\t"}


def scalar(value):
    if isinstance(value, int):
        return str(value)
    text = str(value)
    if (not text or text != text.strip() or text.startswith("-") or text in ("true", "false", "null")
            or PLAIN_NUMBER.match(text) or MUST_QUOTE.search(text)):
        return '"' + "".join(ESCAPES.get(c, c) for c in text) + '"'
    return text


def refuse(message, help_line=None, code="VALIDATION_ERROR", status=2):
    print("error: " + scalar(message))
    print("code: " + code)
    if help_line:
        print("help[1]: " + scalar(help_line))
    sys.exit(status)


def flags(args, valued, switches):
    found, positional, args = {}, [], list(args)
    while args:
        arg = args.pop(0)
        name, eq, value = arg.partition("=")
        if not arg.startswith("-"):
            positional.append(arg)
        elif name in valued:
            found[name] = value if eq else args.pop(0) if args else ""
            found.setdefault(name + "+", []).append(found[name])
        elif arg in switches:
            found[arg] = True
        else:
            refuse("Unknown flag: " + name, "Run the command with --help to see supported flags")
    return found, positional


def split(value):
    return value.split(",") if isinstance(value, str) else value or []


def day(stamp):
    return datetime.datetime.fromisoformat(stamp).astimezone().date().isoformat() if stamp else "-"


def flying(row):
    """Say whether the row is in flight: one status column cannot hold in flight and held, so a held lane is its assignee, and a woken hold keeps it."""
    status, meta = row.get("status"), row.get("metadata") or {}
    if "followup" in meta:  # A promise is never in flight: its in_progress status is the delivery lock.
        return False
    return status == "in_progress" or (bool(row.get("assignee")) and (status in HELD or (status == "open" and "hold_reason" in meta)))


def holding(row):
    """Say whether the hold still holds: on_hold and blocked until someone clears them, deferred until the moment bd reads as due."""
    status, until = row.get("status"), row.get("defer_until")
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return status in HELD and (status != "deferred" or not until or until > now)


def mentions(row):
    """The rows a row links to: its edges alone, since a body's lines became edges when written (bin/jg-beads-links.py)."""
    return {d["depends_on_id"] for d in row.get("dependencies") or [] if d.get("type") != "tracks"}


def legacy(row):
    meta = row.get("metadata") or {}
    return [meta[name] for name in ("task", "legacy_item", "legacy_id", "legacy_twin") if meta.get(name)]


def named(rows, ident):
    """The row with this id, else the one row that carried it before the move; two claimants read as none."""
    hits = [row for row in rows if row["id"] == ident] or [row for row in rows if ident in legacy(row)]
    return hits[0] if len(hits) == 1 else None


PARTIAL = bool(os.environ.get("JG_BEADS_PARTIAL"))  # the rows are a part of the store: a row left out is closed


def task(row, rows, native=None):
    """native is bd blocked's answer as {id: [open blockers]}; None works the answer out from the blocks edges."""
    meta = row.get("metadata") or {}
    closed = row.get("status") == "closed"
    deps = [d["depends_on_id"] for d in row.get("dependencies") or [] if d.get("type") == "blocks"]
    # bd blocked does not speak for a closed row, so it keeps the edge answer.
    waiting = [d for d in deps if rows.get(d, {"status": "closed"} if PARTIAL else {}).get("status") != "closed"] if native is None or closed else native.get(row["id"], [])
    until = (row.get("defer_until") or "-")[:10]
    links = ["pr:" + url for url in dict.fromkeys(filter(None, [row.get("external_ref"), *split(meta.get("prs"))]))]
    links += ["report:" + path for path in split(meta.get("reports"))]
    repos = [label[8:] for label in row.get("labels") or [] if label.startswith("project:")]
    return {
        "id": row["id"], "title": row.get("title", ""), "state": "in_flight" if flying(row) else STATE.get(row.get("status"), "queued"),
        "blocked": "yes" if waiting else "no", "blocked_by": ",".join(waiting) or "none",
        "held": "yes" if holding(row) else "no", "hold_reason": meta.get("hold_reason", "-"),
        "hold_kind": meta.get("hold_kind", "-"), "hold_until": until, "kind": meta.get("kind") or CORE.get(row.get("issue_type"), row.get("issue_type", "task")),
        "repo": repos[0] if repos else "-", "priority": row.get("priority", "-"),
        "created": "-" if closed else day(row.get("created_at")), "closed": day(row.get("closed_at")),
        "deps": ",".join("blocked-by:" + d for d in deps) or "none",
        "links": ",".join(links) or "none", "body": row.get("description", ""),
        "mentions": mentions(row), "delivery_state": meta.get("delivery_state", "-"),
        # parent: the parent-child edge's target, else upkeep for the upkeep label; item: the id the home's state files use.
        "parent": next((d["depends_on_id"] for d in row.get("dependencies") or [] if d.get("type") == "parent-child"),
                       "upkeep" if "upkeep" in (row.get("labels") or []) else "-"),
        "item": meta.get("task") or meta.get("legacy_item") or row["id"], "names": legacy(row),
    }


def clip(item, field, hint):
    value, limit = item[field], CLIP.get(field) if hint else None
    if limit and len(value) > limit:
        return "%s\n... (truncated, %d chars total - use %s to see complete text)" % (value[:limit], len(value), hint)
    return value


def table(name, tasks, fields, full=False):
    print("%s[%d]{%s}:" % (name, len(tasks), ",".join(fields)))
    for item in tasks:
        print("  " + ",".join(scalar(clip(item, field, None if full else "show %s --full" % item["id"])) for field in fields))


def card(item, hint=None):
    print("task:")
    for field in SHOW + (["parent"] if item["parent"] != "-" else []):
        value = clip(item, field, hint)
        print("  %s: %s" % (field, scalar(value)))


def show(tasks, args):
    found, ids = flags(args, (), ("--full",))
    if len(ids) != 1:
        refuse("Expected 1 positional argument, got %d" % len(ids), "usage: jg-backlog.sh show <id> [--full]")
    hits = [t for t in tasks if t["id"] == ids[0]] or [t for t in tasks if ids[0] in t["names"]]
    if len(hits) == 1:
        item = hits[0]
        card(item, None if "--full" in found else "--full")
        if item["blocked"] == "yes" and item["state"] != "done":
            print("help[2]:\n  - Run `jg-backlog.sh unblock %s --by <other>` to clear a blocker" % item["id"])
            print("  - Run `jg-backlog.sh start %s` to move it to in flight" % item["id"])
        return
    refuse('Task "%s" not found in this backlog' % ids[0], "Run `jg-backlog.sh list` to see existing tasks", "NOT_FOUND", 1)


def ready(tasks, args, answer=None):
    """answer is bd ready's ids in its order; None is a store read without it."""
    found, _ = flags(args, ("--repo",), ())
    repo = found.get("--repo")
    if answer is None:
        pool = [t for t in tasks if t["state"] == "queued" and t["held"] == "no" and t["blocked"] == "no"]
    else:
        by_id = {t["id"]: t for t in tasks}
        pool = [by_id[ident] for ident in answer if ident in by_id]
    rows = [t for t in pool if t["kind"] != "public-followup" and repo in (None, t["repo"])]
    suffix = " --repo=" + repo if repo else ""
    print("count: %d" % len(rows))
    if rows:
        table("ready", rows, ROW)
    else:
        print("ready: 0 unblocked queued tasks")
    due = [t for t in tasks if t["kind"] == "public-followup" and t["delivery_state"] == "ready" and t["state"] != "done"
           and t["blocked"] == "no" and repo in (None, t["repo"])]
    if due:
        table("ready_public_followups", due, ROW + ["delivery_state"])
    else:
        print("ready_public_followups: 0 delivery-ready obligations")
    print("help[1]:")
    print("  - Run `jg-backlog.sh start <id>` to dispatch one of these" if rows else
          "  - Run `jg-backlog.sh list --state queued%s` to see all queued work (incl. blocked)" % suffix)


def listing(tasks, args):
    found, _ = flags(args, ("--state", "--repo", "--kind", "--limit", "--fields"), ("--blocked", "--full", "--all"))
    state, repo, kind = (found.get(f) for f in ("--state", "--repo", "--kind"))
    if state is not None and state not in STATES:
        refuse("--state must be one of " + ", ".join(STATES))
    extra = [f for f in found.get("--fields", "").split(",") if f and f not in ROW]
    if set(extra) - set(EXTRA):
        refuse("Unknown field in --fields: " + ",".join(extra))
    rows = [t for t in tasks
            if (state is None or (t["held"] == "yes" if state == "held" else t["state"] == state))
            and (state is not None or "--all" in found or t["state"] != "done")
            and repo in (None, t["repo"]) and kind in (None, t["kind"])
            and ("--blocked" not in found or t["blocked"] == "yes")]
    total = len(rows)
    if "--limit" in found:
        if not found["--limit"].isdigit():
            refuse("--limit must be a whole number")
        rows = rows[:int(found["--limit"])]
    print("count: %d" % len(rows) + (" of %d total" % total if len(rows) < total else ""))
    if not rows:
        named = [state or ""] + ["%s=%s" % pair for pair in (("repo", repo), ("kind", kind)) if pair[1]]
        print("tasks: 0 %s" % "".join(word + " " for word in named if word) + "tasks in this backlog")
        if not (state or repo or kind):
            print('help[2]:\n  - "Run `jg-backlog.sh add <id> \\"<title>\\"` to add a task"')
            print("  - Run `jg-backlog.sh list --state done` to see completed work")
        return
    table("tasks", rows, ROW + extra, "--full" in found)
    both = not state and not kind
    print("help[%d]:" % (2 if both else 1))
    print("  - Run `jg-backlog.sh show <id>` for full notes on a task")
    if both:
        print("  - Run `jg-backlog.sh ready%s` to see unblocked queued work" % (" --repo=" + repo if repo else ""))


def file_row(item, items):
    links = [] if item["links"] == "none" else item["links"].split(",")
    waiting = [] if item["blocked_by"] == "none" else item["blocked_by"].split(",")
    words = ["- [%s] %s - %s" % ("x" if item["state"] == "done" else " ", item["item"], item["title"])]
    words += [link.partition(":")[2] for link in links]
    words += ["blocked-by: " + items.get(ident, ident) for ident in waiting]
    tags = [("repo", item["repo"]), ("kind", "-" if item["kind"] == "task" else item["kind"]), ("priority", item["priority"])]
    if item["held"] == "yes" or (item["state"] == "done" and item["hold_kind"] != "-"):
        # A closed row keeps its hold kind and reason: a non-release answer is not a delivery.
        reason = base64.b64encode(item["hold_reason"].encode()).decode()
        tags += [("hold", "jg-hold-v1:" + reason), ("hold-kind", item["hold_kind"]), ("hold-until", item["hold_until"])]
    words += ["(%s: %s)" % tag for tag in tags if tag[1] != "-"]
    if item["state"] != "done":
        words += [] if item["created"] == "-" else ["(since %s)" % item["created"]]
    else:
        verb = "merged" if any(l.startswith("pr:") for l in links) else "reported" if links else "done"
        words.append("(%s %s)" % (verb, item["closed"]))
    return " ".join(words)


def markdown(tasks, args):
    flags(args, (), ())
    items = {item["id"]: item["item"] for item in tasks}
    print("# Backlog")
    for heading, state in (("In flight", "in_flight"), ("Queued", "queued"), ("Done", "done")):
        print("\n## " + heading)
        for item in tasks:
            if item["state"] == state:
                print(file_row(item, items))
                # The parent edge reads as the parent: line it came from, so a reader of this file sees the edge too.
                edge = [] if item["parent"] == "-" or re.search(r"^\s*parent:", item["body"], re.M) else ["parent: " + items.get(item["parent"], item["parent"])]
                print("".join("  %s\n" % line for line in [*item["body"].splitlines(), *edge] if line.strip()), end="")


def links(tasks, args):
    """Print the ids linked to one row in either direction, one per line; a moved row answers to its old names too."""
    if len(args) != 1:
        refuse("Expected 1 positional argument, got %d" % len(args), "usage: links <id>")

    def claimed(name):
        return [item for item in tasks if item["id"] == name] or [item for item in tasks if name in item["names"]]

    own = claimed(args[0])
    own = own[0] if len(own) == 1 else None
    words = {args[0], own["id"], *own["names"]} if own else {args[0]}
    linked = {item["id"] for item in tasks if words & item["mentions"]}
    for name in own["mentions"] if own else ():
        linked |= {item["id"] for item in claimed(name)}
    print("\n".join(sorted(ident for ident in linked if ident not in words)))


def beads_answer(variable):
    """The rows bd printed into the file this variable names, or None when the caller asked bd nothing."""
    path = os.environ.get(variable)
    if not path:
        return None
    with open(path) as handle:
        return json.load(handle) or []


def one(ident):
    """Turn `bd show <id> --json` into the rows a read works on: the row, its edges in the store's shape, and its edge targets' statuses."""
    row = (json.load(sys.stdin) or [{}])[0]
    if row.get("id") != ident:
        sys.exit(1)
    edges = row.get("dependencies") or []
    row["dependencies"] = [{"depends_on_id": d["id"], "type": d.get("dependency_type")} for d in edges]
    print(json.dumps([row] + [{"id": d["id"], "status": d.get("status")} for d in edges]))


def main():
    if sys.argv[1:2] == ["--one"]:
        return one(sys.argv[2])
    raw = json.load(sys.stdin) or []
    rows = {row["id"]: row for row in raw}
    blocked = beads_answer("JG_BEADS_BLOCKED")
    native = None if blocked is None else {item["id"]: list(item.get("blocked_by") or []) for item in blocked}
    ready_rows = beads_answer("JG_BEADS_READY")
    answer = None if ready_rows is None else [item["id"] for item in ready_rows]
    tasks = sorted((task(row, rows, native) for row in raw), key=lambda t: (rows[t["id"]].get("created_at") or "", t["id"]))
    tasks.sort(key=lambda t: rows[t["id"]].get("closed_at") or "", reverse=True)
    tasks.sort(key=lambda t: ["in_flight", "queued", "done"].index(t["state"]))
    verb = sys.argv[1] if len(sys.argv) > 1 else ""
    serve = {"show": show, "view": show, "ready": lambda t, a: ready(t, a, answer), "list": listing, "markdown": markdown, "links": links}.get(verb)
    if serve is None:
        refuse("Unknown read verb: " + verb)
    serve(tasks, sys.argv[2:])


if __name__ == "__main__":
    main()
