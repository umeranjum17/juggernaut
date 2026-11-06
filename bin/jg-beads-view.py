#!/usr/bin/env python3
"""jg-beads-view.py - render bd rows in the read shape tasks-axi prints.

Usage: jg-beads.sh list --all --limit 0 --json | jg-beads-view.py <list|ready|show|view> [args...]

Reads stdin only, for bin/jg-tasks-axi-lib.sh's jg_backlog_beads_read, and never starts bd.
bin/jg-beads-write.py imports it, so a write answers in the same shape.
A held row is status on_hold, blocked or deferred, and reads as queued; kind is metadata.kind, else issue_type;
parent is the parent-child edge target (upkeep by label) and item metadata.legacy_item, both only through --fields;
repo is the project:<repo> label; links are external_ref, metadata.prs and metadata.reports.
Refusals print tasks-axi's error lines on stdout: exit 2 for a bad flag, exit 1 for an unknown id.
"""
import json
import re
import sys

STATE = {"in_progress": "in_flight", "closed": "done"}
HELD = {"on_hold", "blocked", "deferred"}
ROW = ["id", "state", "kind", "repo", "title"]
SHOW = ["id", "title", "state", "blocked", "blocked_by", "held", "hold_reason", "hold_kind", "hold_until",
        "kind", "repo", "priority", "created", "closed", "deps", "links", "body"]
EXTRA = sorted(set(SHOW) - set(ROW)) + ["delivery_state", "parent", "item"]
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


def task(row, rows):
    meta = row.get("metadata") or {}
    closed = row.get("status") == "closed"
    deps = [d["depends_on_id"] for d in row.get("dependencies") or [] if d.get("type") == "blocks"]
    waiting = [d for d in deps if rows.get(d, {}).get("status") != "closed"]
    held = row.get("status") in HELD
    links = ["pr:" + url for url in dict.fromkeys(filter(None, [row.get("external_ref"), *split(meta.get("prs"))]))]
    links += ["report:" + path for path in split(meta.get("reports"))]
    repos = [label[8:] for label in row.get("labels") or [] if label.startswith("project:")]
    return {
        "id": row["id"], "title": row.get("title", ""), "state": STATE.get(row.get("status"), "queued"),
        "blocked": "yes" if waiting else "no", "blocked_by": ",".join(waiting) or "none",
        "held": "yes" if held else "no", "hold_reason": meta.get("hold_reason", "-") if held else "-",
        "hold_kind": meta.get("hold_kind", "-") if held else "-",
        "hold_until": (row.get("defer_until") or "-")[:10], "kind": meta.get("kind") or row.get("issue_type", "task"),
        "repo": repos[0] if repos else "-", "priority": row.get("priority", "-"),
        "created": "-" if closed else (row.get("created_at") or "-")[:10], "closed": (row.get("closed_at") or "-")[:10],
        "deps": ",".join("blocked-by:" + d for d in deps) or "none",
        "links": ",".join(links) or "none", "body": row.get("description", ""),
        "delivery_state": meta.get("delivery_state", "-"),
        # parent: the parent-child edge's target, else upkeep for the upkeep label; item: the id the home's state files use.
        "parent": next((d["depends_on_id"] for d in row.get("dependencies") or [] if d.get("type") == "parent-child"),
                       "upkeep" if "upkeep" in (row.get("labels") or []) else "-"),
        "item": meta.get("legacy_item") or row["id"],
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
    for field in SHOW:
        value = clip(item, field, hint)
        print("  %s: %s" % (field, scalar(value)))


def show(tasks, args):
    found, ids = flags(args, (), ("--full",))
    if len(ids) != 1:
        refuse("Expected 1 positional argument, got %d" % len(ids), "usage: tasks-axi show <id> [--full]")
    for item in tasks:
        if item["id"] == ids[0]:
            card(item, None if "--full" in found else "--full")
            if item["blocked"] == "yes" and item["state"] != "done":
                print("help[2]:\n  - Run `tasks-axi unblock %s --by <other>` to clear a blocker" % ids[0])
                print("  - Run `tasks-axi start %s` to move it to in flight" % ids[0])
            return
    refuse('Task "%s" not found in this backlog' % ids[0], "Run `tasks-axi list` to see existing tasks", "NOT_FOUND", 1)


def ready(tasks, args):
    found, _ = flags(args, ("--repo",), ())
    repo = found.get("--repo")
    rows = [t for t in tasks if t["state"] == "queued" and t["held"] == "no" and t["blocked"] == "no"
            and repo in (None, t["repo"])]
    suffix = " --repo=" + repo if repo else ""
    print("count: %d" % len(rows))
    if rows:
        table("ready", rows, ROW)
    else:
        print("ready: 0 unblocked queued tasks")
    print("ready_public_followups: 0 delivery-ready obligations")
    print("help[1]:")
    print("  - Run `tasks-axi start <id>` to dispatch one of these" if rows else
          "  - Run `tasks-axi list --state queued%s` to see all queued work (incl. blocked)" % suffix)


def listing(tasks, args):
    found, _ = flags(args, ("--state", "--repo", "--kind", "--limit", "--fields"), ("--blocked", "--full"))
    state, repo, kind = (found.get(f) for f in ("--state", "--repo", "--kind"))
    if state is not None and state not in STATES:
        refuse("--state must be one of " + ", ".join(STATES))
    extra = [f for f in found.get("--fields", "").split(",") if f and f not in ROW]
    if set(extra) - set(EXTRA):
        refuse("Unknown field in --fields: " + ",".join(extra))
    rows = [t for t in tasks
            if (state is None or (t["held"] == "yes" if state == "held" else t["state"] == state))
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
            print('help[2]:\n  - "Run `tasks-axi add <id> \\"<title>\\"` to add a task"')
            print("  - Run `tasks-axi list --state done` to see completed work")
        return
    table("tasks", rows, ROW + extra, "--full" in found)
    both = not state and not kind
    print("help[%d]:" % (2 if both else 1))
    print("  - Run `tasks-axi show <id>` for full notes on a task")
    if both:
        print("  - Run `tasks-axi ready%s` to see unblocked queued work" % (" --repo=" + repo if repo else ""))


def main():
    raw = json.load(sys.stdin) or []
    rows = {row["id"]: row for row in raw}
    tasks = sorted((task(row, rows) for row in raw), key=lambda t: (rows[t["id"]].get("created_at") or "", t["id"]))
    tasks.sort(key=lambda t: rows[t["id"]].get("closed_at") or "", reverse=True)
    tasks.sort(key=lambda t: ["in_flight", "queued", "done"].index(t["state"]))
    verb = sys.argv[1] if len(sys.argv) > 1 else ""
    serve = {"show": show, "view": show, "ready": ready, "list": listing}.get(verb)
    if serve is None:
        refuse("Unknown read verb: " + verb)
    serve(tasks, sys.argv[2:])


if __name__ == "__main__":
    main()
