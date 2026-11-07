#!/usr/bin/env python3
"""jg-beads-write.py - serve the backlog's add, update, done, block, unblock, start, reopen, hold and unhold on a Beads store.

Usage: BEADS_DIR=<store> jg-beads-write.py <add|create|update|edit|done|close|block|unblock|start|reopen|hold|unhold|relink> [args...]
       BEADS_DIR=<store> jg-beads-write.py <stage <key>...|take <file> <key>...|drop <key>...|public-followup ...>

bin/jg-tasks-axi-lib.sh's jg_backlog_beads_write starts it after bin/jg-tasks-axi.sh's intake and captain guards.
Every bd call goes through bin/jg-beads.sh. Replies and refusals print the backlog's lines on stdout.
kind captain is bd's decision type and shows to callers as captain, any other kind is metadata.kind, repo is the project:<repo> label, the first PR is external_ref, later ones are metadata.prs,
and reports are metadata.reports, each comma-joined; a PR or report also joins the title, as the backlog writes it.
A hold is status on_hold with metadata.hold_reason and hold_kind, kept in plain text; a dated hold is status deferred
with --until as defer_until at UTC midnight, because bd reads a bare date in local time, and bd ready wakes it to open;
a held row keeps its assignee, and that owner is what keeps it in flight, across that wake too.
--archive-body needs nothing further: the store's own history keeps the replaced body.
--mint leaves the id to bd, which names it under the store's prefix. A rerun converges: an existing id, blocker, link or note is left alone. bd refuses an id with no dash and a dependency
cycle, and that refusal reaches stderr with bd's exit status.
start, reopen and done move status only from the status they expect, so a row that moved first exits 13 and changes
nothing, with one refusal line on stdout. A held row keeps its status on reopen. start takes an open row or a deferred
row past its date: one status column cannot read in flight and held at once, so where the backlog would start a held or
done row this refuses.
A worker's lane owns its row: the assignee is the lane named by JG_BACKLOG_LANE and metadata.agent is JG_BACKLOG_AGENT.
start claims a row with no owner, and JG_BACKLOG_LANE_HANDOVER=1 takes it from the owner it read, so a row another lane
took first exits 13. done keeps the assignee as history, reopen clears both, and each moves only from the owner it read.
With no lane named, start claims an unowned row for the actor (BEADS_ACTOR, else juggernaut), so every in-flight row has an owner.
bin/jg-beads.sh makes the lane the actor of every bd call, so a comment or an event carries who wrote it.
bd takes --if-assignee or --force, never both, so closing a blocked row or a parent with an open child is guarded by status alone.
stage, take and drop move queued rows, and bd export and bd import carry them.
stage prints rows as a backlog file, or with --native as export lines, and refuses to leave an active dependent behind.
take files rows from either in one bd import, skips any already here, and refuses a blocker that neither moves nor is here.
A backlog file's rows carry what its format holds, and the since date stays behind. drop deletes rows filed elsewhere, in
one bd call, and leaves any row that moved out of the queue.
A body's linked-to: and parent: lines become edges when written (bin/jg-beads-links.py), and a new row takes the lines that named it first.
A body that drops a name drops its edge, an edge bd refuses as a cycle lands as related, and unhold eases a line's blocks edge to related
once neither side is a decision. relink lays every missing edge, for a store whose lines came before edges.
"""
import datetime
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
view = __import__("jg-beads-view")
edges = __import__("jg-beads-links")

WRAPPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "jg-beads.sh")
PR = re.compile(r"https://(github\.com/[^/\s]+/[^/\s]+/pull|[^/\s]+/[^/\s]+/[^/\s]+/pulls)/\d+\Z")
REPORT = re.compile(r"data/[^/\s]+/report\.md\Z")
LABEL = {"queued": "Queued", "in_flight": "In flight", "done": "Done"}
PR_ERROR = ("--pr must be a canonical pull request URL: https://github.com/<owner>/<repo>/pull/<n> (GitHub) "
            "or https://<host>/<owner>/<repo>/pulls/<n> (Forgejo)")
FIELDS = ("--kind", "--repo", "--body", "--body-file", "--pr", "--report", "--priority")
STALE = 13
CAPTAIN = "captain"
HOLD_KINDS = ("captain", "external", "load", "parked", "future")
HOLD_FIELDS = ("hold_reason", "hold_kind")


def bd(*args):
    run = subprocess.run([WRAPPER, *args], capture_output=True, text=True, check=False)
    if run.returncode == STALE:
        said = [line.split("mismatch: ", 1)[1] for line in (run.stdout + run.stderr).splitlines() if "mismatch: " in line]
        view.refuse("stale write refused: " + (said[0] if said else "the row moved"),
                    f"Run `jg-tasks-axi.sh show {args[1]}` and decide again", "STALE_WRITE", STALE)
    if run.returncode:
        sys.stderr.write(run.stdout + run.stderr)
        sys.exit(run.returncode)
    return run.stdout


def lane(row):
    """Return the flags that make this run's lane the row's owner, or nothing with no lane named."""
    name, agent = os.environ.get("JG_BACKLOG_LANE"), os.environ.get("JG_BACKLOG_AGENT")
    if not name:
        return []
    owner = row.get("assignee") or "" if os.environ.get("JG_BACKLOG_LANE_HANDOVER") else ""
    return ["-a", name, "--if-assignee", owner] + (["--set-metadata", "agent=" + agent] if agent else [])


def unowned(row):
    """Return the flags that give a row with no owner the actor as owner, or nothing when it has one."""
    if row.get("assignee"):
        return []
    return ["-a", os.environ.get("JG_BACKLOG_LANE") or os.environ.get("BEADS_ACTOR") or "juggernaut", "--if-assignee", ""]


def released(row):
    """Return the flags that take a lane off its row, guarded on the owner read."""
    owner = row.get("assignee")
    return ["-a", "", "--unset-metadata", "agent", "--if-assignee", owner] if owner else []


def rows():
    return {row["id"]: row for row in json.loads(bd("list", "--all", "--limit", "0", "--json")) or []}


def lay(ident=None, old=""):
    """Lay the edges of the lines touching one row, or of every line; a name the old body had and the new one lost is unlinked."""
    items = rows()
    if old:
        kept = {side["id"] for line in edges.lines(items, ident) for side in line[:2] if side}
        for word in {word for _, word in edges.named(old)}:
            other = view.named(items.values(), word)
            if other and other["id"] not in kept | {ident}:
                unlink(items[ident], other)
    laid = 0
    for row, other, kind, _ in edges.pending(items, ident):
        if other:
            one, two, kind = edges.edge(row, other, kind)
            if kind == "related" or subprocess.run([WRAPPER, "dep", "add", one["id"], two["id"], "--type", kind],
                                                   capture_output=True, check=False).returncode:
                kind = "related"
                bd("dep", "add", one["id"], two["id"], "--type", kind)
            edges.join(one, two, kind)
            laid += 1
    return laid


def unlink(one, two):
    """Remove the edge between two rows, in whichever direction it was laid."""
    for a, b in ((one, two), (two, one)):
        if any(d["depends_on_id"] == b["id"] for d in a.get("dependencies") or []):
            bd("dep", "remove", a["id"], b["id"])


def eased(ident):
    """Turn the blocks edges of a released row's lines to related, so no row waits on what is no longer a decision."""
    items = rows()
    for row, other, kind, _ in edges.lines(items, ident):
        if other and edges.edge(row, other, kind)[2] == "related" and edges.joined(row, other) == "blocks":
            unlink(row, other)
            bd("dep", "add", row["id"], other["id"], "--type", "related")


def target(items, ident):
    row = view.named(items.values(), ident)
    if row is None:
        view.refuse('Task "%s" not found in this backlog' % ident, "Run `jg-tasks-axi.sh list` to see existing tasks",
                    "NOT_FOUND", 1)
    return row


def plain(items, ident):
    row = target(items, ident)
    if "followup" in (row.get("metadata") or {}):
        view.refuse("Public-followup content and state cannot change through generic commands",
                    "Use `jg-tasks-axi.sh public-followup record-delivery` or `jg-tasks-axi.sh public-followup waive`")
    return row


def blocker(items, ident):
    row = view.named(items.values(), ident)
    if row is None:
        view.refuse('blocker "%s" not found' % ident, "Create the blocker task first, or choose an existing task id")
    return row["id"]


def checked(found):
    """Refuse a bad shared flag and return the new body, or None when the call names none."""
    if "--body" in found and "--body-file" in found:
        view.refuse("Use only one of --body or --body-file")
    if "--pr" in found and not PR.match(found["--pr"]):
        view.refuse(PR_ERROR)
    if "--report" in found and not REPORT.match(found["--report"]):
        view.refuse("--report must be a data/<id>/report.md path")
    if found.get("--priority", "0") not in tuple("01234"):
        view.refuse("--priority must be an integer 0-4")
    if "--body-file" in found:
        with open(found["--body-file"], encoding="utf-8") as source:
            return source.read().rstrip("\n")
    return found.get("--body")


def links(row, found):
    """Return the words a new link adds to the title, and the bd update flags that store it."""
    meta, ref = row.get("metadata") or {}, row.get("external_ref")
    prs, reports = view.split(meta.get("prs")), view.split(meta.get("reports"))
    pr, report = found.get("--pr"), found.get("--report")
    words, cmd = [], []
    if pr and pr != ref and pr not in prs:
        words.append(pr)
        cmd += ["--set-metadata", "prs=" + ",".join(prs + [pr])] if ref else ["--external-ref", pr]
    if report and report not in reports:
        words.append(report)
        cmd += ["--set-metadata", "reports=" + ",".join(reports + [report])]
    return words, cmd


def as_json(item):
    def listed(value):
        return [] if value == "none" else value.split(",")

    def unset(value):
        return None if value == "-" else value

    held = item["held"] == "yes"
    return {
        "id": item["id"], "title": item["title"], "state": item["state"],
        "kind": None if item["kind"] == "task" else item["kind"], "repo": unset(item["repo"]),
        "priority": unset(item["priority"]), "created": unset(item["created"]), "closed": unset(item["closed"]),
        "deps": [{"type": "blocked-by", "id": dep.partition(":")[2]} for dep in listed(item["deps"])],
        "hold": {"reason": unset(item["hold_reason"]), "kind": unset(item["hold_kind"]),
                 "until": unset(item["hold_until"])} if held else None,
        "links": [dict(zip(("kind", "url"), link.split(":", 1))) for link in listed(item["links"])],
        "body": item["body"] or None, "blocked": item["blocked"] == "yes", "blocked_by": listed(item["blocked_by"]),
        "held": held,
    }


def respond(found, action, ident, line, tips, card=True, **extra):
    items = rows()
    item = view.task(items[ident], items)
    if "--json" in found:
        print(json.dumps({"ok": True, "action": action, **extra, "task": as_json(item)}, indent=2))
        return
    print("ok: " + line)
    if extra.get("already"):
        print("already: true")
    if card:
        view.card(item, "show %s --full" % ident)
    print("help[%d]:" % len(tips))
    for tip in tips:
        print("  - " + tip)


def tips_for(ident):
    return ["Run `jg-tasks-axi.sh start %s` to move it to in flight" % ident,
            "Run `jg-tasks-axi.sh block %s --by <other>` to record a dependency" % ident]


def add(args):
    found, words = view.flags(args, FIELDS + ("--prefix", "--blocked-by", "--label"), ("--queue", "--mint", "--json"))
    if "--mint" in found:
        if len(words) != 1 or not words[0]:
            view.refuse("--mint requires a title", 'Run `jg-tasks-axi.sh add "<title>" --mint`')
        if "--prefix" in found:
            view.refuse("--prefix cannot go with --mint: bd names a minted id under the store's own prefix",
                        'Run `jg-tasks-axi.sh add <prefix>-<name> "<title>"` to choose the id')
    elif not 1 <= len(words) <= 2:
        view.refuse("Expected 1-2 positional arguments, got %d" % len(words), 'usage: jg-tasks-axi.sh add <id> "<title>" [flags]')
    elif len(words) == 1:
        view.refuse("A title is required", 'Run `jg-tasks-axi.sh add <id> "<title>"`')
    body = checked(found)
    items = rows()
    title = words[-1]
    ident = None if "--mint" in found else words[0]
    known = ident and view.named(items.values(), ident)
    if known:
        state = LABEL[view.task(known, items)["state"]]
        lay(known["id"])
        respond(found, "add", ident, "add %s already exists -> %s" % (ident, state), tips_for(ident), already=True)
        return
    blockers = [blocker(items, other) for other in found.get("--blocked-by+", [])]
    meta = {"kind": found["--kind"]} if found.get("--kind", CAPTAIN) != CAPTAIN else {}
    if "--report" in found:
        meta["reports"] = found["--report"]
    cmd = ["create", "--title=" + " ".join(filter(None, [title, found.get("--pr"), found.get("--report")]))]
    cmd += ["--json"] if ident is None else ["--id", ident, "--force"]
    cmd += ["--type", "decision"] if found.get("--kind") == CAPTAIN else []
    for flag, value in (("-p", found.get("--priority")), ("--external-ref", found.get("--pr")),
                        ("--deps", ",".join(blockers)), ("--metadata", meta and json.dumps(meta))):
        cmd += [flag, value] if value else []
    cmd += ["--description=" + body] if body else []
    cmd += ["-l", "project:" + found["--repo"]] if "--repo" in found else []
    cmd += ["-l", found["--label"]] if "--label" in found else []
    made = bd(*cmd)
    ident = ident or json.loads(made)["id"]
    lay(ident)
    named = [found[f] if f == "--kind" else "repo " + found[f] for f in ("--kind", "--repo") if f in found]
    line = "added %s%s -> Queued" % (ident, " (%s)" % ", ".join(named) if named else "")
    respond(found, "add", ident, line, tips_for(ident))


def update(args):
    found, ids = view.flags(args, FIELDS + ("--title",), ("--archive-body", "--json"))
    if len(ids) != 1:
        view.refuse("Expected 1 positional argument, got %d" % len(ids), "usage: jg-tasks-axi.sh update <id> [flags]")
    items = rows()
    row = plain(items, ids[0])
    ident = row["id"]
    item = view.task(row, items)
    if not set(found) - {"--json"}:
        view.refuse("Nothing to update", "Pass a field, e.g. --title, --body, --body-file, --repo, or --kind")
    body = checked(found)
    if "--archive-body" in found and body is None:
        view.refuse("--archive-body requires --body or --body-file",
                    "Inspect the current task first, then pass a replacement body with --body or --body-file")
    words, cmd = links(row, found)
    title = " ".join([found.get("--title", item["title"]), *words])
    changed = []
    if title != item["title"]:
        cmd.append("--title=" + title)
    if found.get("--title", item["title"]) != item["title"]:
        changed.append("title")
    if body is not None and body != item["body"]:
        cmd.append("--description=" + body)
        changed += ["body", "archive"] if "--archive-body" in found else ["body"]
    if found.get("--repo", item["repo"]) != item["repo"]:
        cmd += [] if item["repo"] == "-" else ["--remove-label", "project:" + item["repo"]]
        cmd += ["--add-label", "project:" + found["--repo"]]
        changed.append("repo")
    if found.get("--kind", item["kind"]) != item["kind"]:
        # Captain is bd's decision type; any other kind is metadata on a task. A row from before keeps kind in metadata.
        cmd += ["--type", "decision", "--unset-metadata", "kind"] if found["--kind"] == CAPTAIN else \
            ["--set-metadata", "kind=" + found["--kind"]] + (["--type", "task"] if row.get("issue_type") == "decision" else [])
        changed.append("kind")
    if found.get("--priority", str(item["priority"])) != str(item["priority"]):
        cmd += ["-p", found["--priority"]]
        changed.append("priority")
    if words:
        changed.append("links")
    tips = ["Run `jg-tasks-axi.sh show %s --full` to see the result" % ident]
    if not cmd:
        respond(found, "update", ident, "updated %s already" % ident, tips, already=True)
        return
    bd("update", ident, *cmd)
    if "body" in changed:
        lay(ident, item["body"])
    respond(found, "update", ident, "updated %s (%s)" % (ident, ", ".join(changed)), tips, changed=changed)


def done(args):
    found, ids = view.flags(args, ("--pr", "--report", "--note", "--keep"), ("--no-prune", "--json"))
    if len(ids) != 1:
        view.refuse("Expected 1 positional argument, got %d" % len(ids), "usage: jg-tasks-axi.sh done <id> [flags]")
    checked(found)
    items = rows()
    row = plain(items, ids[0])
    ident = row["id"]
    item = view.task(row, items)
    already = item["state"] == "done"
    words, cmd = links(row, found)
    if words:
        cmd.append("--title=" + " ".join([item["title"], *words]))
    note = found.get("--note")
    if note and note not in item["body"].split("\n"):
        cmd.append("--description=" + "\n".join(filter(None, [item["body"], note])))
    if not already:
        cmd += ["--status", "closed", "--if-status", row["status"]]
        kids = any(d.get("type") == "parent-child" and d["depends_on_id"] == ident and other["status"] != "closed"
                   for other in items.values() for d in other.get("dependencies") or [])
        if item["blocked"] == "yes" or kids:
            cmd.append("--force")
        elif row.get("assignee"):
            cmd += ["--if-assignee", row["assignee"]]
    if cmd:
        bd("update", ident, *cmd)
    tail = "".join(" (%s %s)" % (name, found["--" + name]) for name in ("pr", "report") if "--" + name in found)
    line = "done %s%s -> Done%s" % (ident, " already" if already else "", tail)
    tips = ["Run `jg-tasks-axi.sh ready` to dispatch work unblocked by this"]
    extra = {"already": True} if already else {}
    respond(found, "done", ident, line, tips, card=False, **extra, pruned=0)


def block(args):
    found, ids = view.flags(args, ("--by",), ("--json",))
    if len(ids) != 1:
        view.refuse("Expected 1 positional argument, got %d" % len(ids), "usage: jg-tasks-axi.sh block <id> --by <other>")
    ident, other = ids[0], found.get("--by")
    if not other:
        view.refuse("--by <id> is required", "Name the other task, e.g. `--by treehouse-lease-t4`")
    items = rows()
    row = target(items, ident)
    ident, item = row["id"], view.task(row, items)
    other = blocker(items, other)
    if ident == other:
        view.refuse("A task cannot block itself")
    if (row.get("metadata") or {}).get("delivery_state", "ready") not in ("intent", "pending-work", "ready"):
        view.refuse("Cannot add blockers after public delivery has started")
    already = "blocked-by:" + other in item["deps"].split(",")
    if not already:
        bd("dep", "add", ident, other)
    tips = ["Run `jg-tasks-axi.sh unblock %s --by <other>` to clear it" % ident,
            "Run `jg-tasks-axi.sh ready` to see what is still dispatchable"]
    line = "block %s %s %s" % (ident, "already blocked-by" if already else "-> blocked-by", other)
    extra = {"already": True} if already else {}
    respond(found, "block", ident, line, tips, card=False, **extra, blocked_by=other)


def unblock(args):
    found, ids = view.flags(args, ("--by",), ("--json",))
    if len(ids) != 1:
        view.refuse("Expected 1 positional argument, got %d" % len(ids), "usage: jg-tasks-axi.sh unblock <id> --by <other>")
    if not found.get("--by"):
        view.refuse("--by <id> is required", "Name the other task, e.g. `--by treehouse-lease-t4`")
    items = rows()
    row = target(items, ids[0])
    other = view.named(items.values(), found["--by"])
    ident, other = row["id"], other["id"] if other else found["--by"]
    already = "blocked-by:" + other not in view.task(row, items)["deps"].split(",")
    if not already:
        bd("dep", "remove", ident, other)
    tips = ["Run `jg-tasks-axi.sh ready` to see newly unblocked work"]
    line = "unblock %s %s %s" % (ident, "already not blocked-by" if already else "-> cleared", other)
    extra = {"already": True} if already else {}
    respond(found, "unblock", ident, line, tips, card=False, **extra, blocked_by=other)


def one_row(verb, args):
    found, ids = view.flags(args, (), ("--json",))
    if len(ids) != 1:
        view.refuse("Expected 1 positional argument, got %d" % len(ids), "usage: the backlog %s <id>" % verb)
    row = plain(rows(), ids[0])
    return found, row["id"], row


def start(args):
    found, ident, row = one_row("start", args)
    tips = ["Run `jg-tasks-axi.sh done %s --pr <url>` when it ships" % ident]
    owner, status, held = lane(row) or unowned(row), row["status"], view.holding(row)
    mine = owner and row.get("assignee") == owner[1]
    if status == "in_progress" or (held and view.flying(row)):
        if owner and not mine:
            bd("update", ident, *owner, "--if-status", status)
        respond(found, "start", ident, "start %s already in flight" % ident, tips, card=False, already=True)
        return
    # A due row is deferred until the first bd ready wakes it to open; a lane held in flight comes back to its row.
    due = status == "deferred" and not held
    bd("update", ident, "--status", "in_progress", "--if-status", "deferred" if due else "open", *(["--defer", ""] if due else []), *([] if mine else owner))
    respond(found, "start", ident, "start %s -> In flight" % ident, tips, card=False)


def reopen(args):
    found, ident, row = one_row("reopen", args)
    tips = ["Run `jg-tasks-axi.sh start %s` to move it to in flight" % ident]
    if row["status"] not in ("in_progress", "closed"):
        if row.get("assignee"):
            bd("update", ident, *released(row), "--if-status", row["status"])
        respond(found, "reopen", ident, "reopen %s already queued" % ident, tips, card=False, already=True)
        return
    bd("update", ident, "--status", "open", "--if-status", row["status"], *released(row))
    respond(found, "reopen", ident, "reopen %s -> Queued" % ident, tips, card=False)


def hold_date(value):
    try:
        datetime.date.fromisoformat(value if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value) else "")
    except ValueError:
        view.refuse("--until must be YYYY-MM-DD")
    return value


def hold(args):
    found, ids = view.flags(args, ("--reason", "--kind", "--until"), ("--json",))
    if len(ids) != 1:
        view.refuse("Expected 1 positional argument, got %d" % len(ids), "usage: jg-tasks-axi.sh hold <id> --reason <text>")
    reason, kind = found.get("--reason"), found.get("--kind")
    if reason is None:
        view.refuse("--reason <text> is required", 'Pass a reason, e.g. --reason "captain decision pending"')
    if not reason.strip():
        view.refuse("--reason requires a value", "Pass --reason=... with a non-empty value")
    if kind is not None and kind not in HOLD_KINDS:
        view.refuse("--kind must be one of " + ", ".join(HOLD_KINDS))
    until = hold_date(found["--until"]) if "--until" in found else None
    items = rows()
    row = plain(items, ids[0])
    ident = row["id"]
    item = view.task(row, items)
    tips = ["Run `jg-tasks-axi.sh unhold %s` to resume dispatch" % ident, "Run `jg-tasks-axi.sh list --state held` to review paused work"]
    if item["held"] == "yes" and (item["hold_reason"], item["hold_kind"], item["hold_until"]) == (reason, kind or "-", until or "-"):
        respond(found, "hold", ident, "hold %s already held" % ident, tips, already=True)
        return
    status, meta = row.get("status"), row.get("metadata") or {}
    cmd = ["--set-metadata", "hold_reason=" + reason]
    cmd += ["--set-metadata", "hold_kind=" + kind] if kind else ["--unset-metadata", "hold_kind"] if "hold_kind" in meta else []
    cmd += ["--defer", until + "T00:00:00Z" if until else ""] if until or row.get("defer_until") else []
    cmd += unowned(row) if status == "in_progress" else []
    want = "deferred" if until else "on_hold"
    cmd += ["--status", want] if status not in ("closed", want) else []
    bd("update", ident, *cmd)
    named = ", ".join(filter(None, [kind, until and "until " + until]))
    respond(found, "hold", ident, "hold %s -> held%s" % (ident, " (%s)" % named if named else ""), tips)


def unhold(args):
    found, ids = view.flags(args, (), ("--json",))
    if len(ids) != 1:
        view.refuse("Expected 1 positional argument, got %d" % len(ids), "usage: jg-tasks-axi.sh unhold <id>")
    items = rows()
    row = plain(items, ids[0])
    ident = row["id"]
    meta = row.get("metadata") or {}
    cmd = [word for key in HOLD_FIELDS if key in meta for word in ("--unset-metadata", key)]
    cmd += ["--defer", ""] if row.get("defer_until") else []
    back = "in_progress" if view.flying(row) else "open"
    cmd += ["--status", back] if row.get("status") not in ("closed", back) else []
    tips = ["Run `jg-tasks-axi.sh ready` to see dispatchable work"]
    if not cmd:
        respond(found, "unhold", ident, "unhold %s already not held" % ident, tips, already=True)
        return
    bd("update", ident, *cmd)
    eased(ident)
    respond(found, "unhold", ident, "unhold %s -> cleared" % ident, tips)


def exported():
    name = "export-%d.jsonl" % os.getpid()
    bd("export", "-o", name)
    path = os.path.join(os.path.dirname(os.environ["BEADS_DIR"].rstrip("/")), name)
    with open(path, encoding="utf-8") as source:
        lines = source.read().splitlines()
    os.unlink(path)
    return lines


def stage(args):
    native = args[:1] == ["--native"]
    items = rows()
    picked = [target(items, key) for key in args[native:]]
    moving = {row["id"] for row in picked}
    for row in items.values():
        item = view.task(row, items)
        waits = set(item["blocked_by"].split(",")) & moving
        if waits and row["id"] not in moving and item["state"] != "done":
            view.refuse('Task "%s" is still blocking active tasks: %s' % (sorted(waits)[0], item["item"]),
                        "Move them together, or unblock them first")
    if not native and any("followup" in (row.get("metadata") or {}) for row in picked):
        view.refuse("a public follow-up cannot cross to a backlog file: its record would be lost")
    if native:
        print("".join(line + "\n" for line in exported() if json.loads(line).get("id") in moving), end="")
        return
    names = {ident: view.task(row, items)["item"] for ident, row in items.items()}
    print("## In flight\n\n## Queued\n")
    for row in picked:
        item = view.task(row, items)
        print(view.file_row(item, names))
        print("".join("  %s\n" % line for line in item["body"].splitlines() if line.strip()), end="")
    print("\n## Done")


def file_rows(path):
    """A backlog file's rows as bd import rows, read by the parser the cut uses."""
    parse_item = __import__("jg-beads-migrate").parse_item
    found, row, section = [], None, ""
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(path, encoding="utf-8") as source:
        for line in source.read().splitlines():
            head = re.match(r"- \[(.)\] (\S+)(?: - )?(.*)", line)
            if line.startswith("## "):
                section, row = line[3:].strip(), None
            elif head:
                item = parse_item("", "", section, head)
                words = item["title"].split()
                meta = {"kind": item["kind"], "hold_reason": item["hold"], "hold_kind": item["hold_kind"],
                        "prs": ",".join(item["prs"][1:]), "reports": ",".join(word for word in words if REPORT.match(word))}
                row = {"id": item["item"], "title": item["title"], "status": item["status"], "issue_type": "task",
                       "priority": int(item["priority"] or 2), "description": "", "created_at": stamp, "updated_at": stamp,
                       "metadata": {name: value for name, value in meta.items() if value},
                       "labels": ["project:" + item["repo"]] if item["repo"] else [],
                       "dependencies": [{"issue_id": item["item"], "depends_on_id": other, "type": "blocks"}
                                        for other in item["blocked"]]}
                row.update({"external_ref": item["prs"][0]} if item["prs"] else {})
                row.update({"defer_until": item["hold_until"] + "T00:00:00Z"} if item["hold_until"] else {})
                found.append(row)
            elif row and line.startswith("  "):
                row["description"] += ("\n" if row["description"] else "") + line[2:]
    return found


def take(args):
    path, keys = args[0], args[1:]
    with open(path, encoding="utf-8") as source:
        found = [json.loads(line) for line in source] if path.endswith(".jsonl") else file_rows(path)
    items, picked = rows(), []
    for key in keys:
        row = view.named(found, key)
        if row is None:
            view.refuse('Task "%s" is not in %s' % (key, path))
        if not path.endswith(".jsonl") and row["metadata"].get("kind") == "public-followup":
            view.refuse('Task "%s" is a public follow-up, and a backlog file does not carry its record' % key)
        if "-" not in row["id"]:
            view.refuse('Task "%s" has no dash, and a Beads id needs one' % key, "Rename it first")
        if view.named(items.values(), key) is None:
            picked.append(row)
    moving = {row["id"] for row in picked}
    for row in picked:
        for edge in row.get("dependencies") or []:
            here = view.named(items.values(), edge["depends_on_id"])
            if here:
                edge["depends_on_id"] = here["id"]
            elif edge["depends_on_id"] not in moving and edge.get("type") == "blocks":
                view.refuse('Cannot move "%s": its blocker "%s" would be stranded' % (row["id"], edge["depends_on_id"]),
                            "Add it to the same move, or move it first")
    if picked:
        with open(path + ".take.jsonl", "w", encoding="utf-8") as sink:
            sink.write("".join(json.dumps(row) + "\n" for row in picked))
        bd("import", path + ".take.jsonl")
        os.unlink(path + ".take.jsonl")
        lay()


def drop(keys):
    items = rows()
    found = [row for row in (view.named(items.values(), key) for key in keys) if row]
    moved = [row["id"] for row in found if view.task(row, items)["state"] != "queued"]
    if moved:
        view.refuse("these rows left the queue during the move and stay here: " + ", ".join(moved))
    if found:
        bd("delete", *[row["id"] for row in found], "--force")


def relink(_args):
    print("ok: relink laid %d" % lay())


def main():
    verb = sys.argv[1] if len(sys.argv) > 1 else ""
    serve = {"add": add, "create": add, "update": update, "edit": update, "done": done, "close": done,
             "block": block, "unblock": unblock, "start": start, "reopen": reopen, "hold": hold, "unhold": unhold,
             "stage": stage, "take": take, "drop": drop, "relink": relink,
             "public-followup": lambda args: __import__("jg-beads-followup").main(args)}.get(verb)
    if serve is None:
        view.refuse("Unknown write verb: " + verb)
    serve(sys.argv[2:])


if __name__ == "__main__":
    main()
