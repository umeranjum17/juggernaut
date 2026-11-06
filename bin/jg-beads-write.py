#!/usr/bin/env python3
"""jg-beads-write.py - serve tasks-axi's add, update, done and block on a Beads store.

Usage: BEADS_DIR=<store> jg-beads-write.py <add|create|update|edit|done|close|block> [args...]

bin/jg-tasks-axi-lib.sh's jg_backlog_beads_write starts it after bin/jg-tasks-axi.sh's intake and captain guards.
Every bd call goes through bin/jg-beads.sh. Replies and refusals print tasks-axi's lines on stdout.
kind is metadata.kind, repo is the project:<repo> label, the first PR is external_ref, later ones are metadata.prs,
and reports are metadata.reports, each comma-joined; a PR or report also joins the title, as tasks-axi writes it.
A rerun converges: an existing id, blocker, link or note is left alone. bd refuses an id with no dash and a dependency
cycle, and that refusal reaches stderr with bd's exit status.
"""
import hashlib
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
view = __import__("jg-beads-view")

WRAPPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "jg-beads.sh")
PR = re.compile(r"https://(github\.com/[^/\s]+/[^/\s]+/pull|[^/\s]+/[^/\s]+/[^/\s]+/pulls)/\d+\Z")
REPORT = re.compile(r"data/[^/\s]+/report\.md\Z")
LABEL = {"queued": "Queued", "in_flight": "In flight", "done": "Done"}
PR_ERROR = ("--pr must be a canonical pull request URL: https://github.com/<owner>/<repo>/pull/<n> (GitHub) "
            "or https://<host>/<owner>/<repo>/pulls/<n> (Forgejo)")
FIELDS = ("--kind", "--repo", "--body", "--body-file", "--pr", "--report", "--priority")


def bd(*args):
    run = subprocess.run([WRAPPER, *args], capture_output=True, text=True, check=False)
    if run.returncode:
        sys.stderr.write(run.stdout + run.stderr)
        sys.exit(run.returncode)
    return run.stdout


def rows():
    return {row["id"]: row for row in json.loads(bd("list", "--all", "--limit", "0", "--json")) or []}


def target(items, ident):
    if ident not in items:
        view.refuse('Task "%s" not found in this backlog' % ident, "Run `tasks-axi list` to see existing tasks",
                    "NOT_FOUND", 1)
    return items[ident]


def blocker(items, ident):
    if ident not in items:
        view.refuse('blocker "%s" not found' % ident, "Create the blocker task first, or choose an existing task id")


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


def minted(title, prefix, items):
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:48].rstrip("-") or "task"
    stem = prefix + "-" + slug if prefix else slug
    for salt in range(256):
        ident = "%s-%s" % (stem, hashlib.sha256(("%s:%d" % (title, salt)).encode()).hexdigest()[:2])
        if ident not in items:
            return ident
    return view.refuse("no free id for this title")


def add(args):
    found, words = view.flags(args, FIELDS + ("--prefix", "--blocked-by"), ("--queue", "--mint", "--json"))
    if "--mint" in found:
        if len(words) != 1 or not words[0]:
            view.refuse("--mint requires a title", 'Run `tasks-axi add "<title>" --mint`')
    elif not 1 <= len(words) <= 2:
        view.refuse("Expected 1-2 positional arguments, got %d" % len(words), 'usage: tasks-axi add <id> "<title>" [flags]')
    elif len(words) == 1:
        view.refuse("A title is required", 'Run `tasks-axi add <id> "<title>"`')
    body = checked(found)
    items = rows()
    title = words[-1]
    ident = minted(title, found.get("--prefix"), items) if "--mint" in found else words[0]
    tips = ["Run `tasks-axi start %s` to move it to in flight" % ident,
            "Run `tasks-axi block %s --by <other>` to record a dependency" % ident]
    if ident in items:
        state = LABEL[view.task(items[ident], items)["state"]]
        respond(found, "add", ident, "add %s already exists -> %s" % (ident, state), tips, already=True)
        return
    blockers = found.get("--blocked-by+", [])
    for other in blockers:
        blocker(items, other)
    meta = {"kind": found["--kind"]} if "--kind" in found else {}
    if "--report" in found:
        meta["reports"] = found["--report"]
    cmd = ["create", "--title=" + " ".join(filter(None, [title, found.get("--pr"), found.get("--report")])),
           "--id", ident, "--force"]
    for flag, value in (("-p", found.get("--priority")), ("--external-ref", found.get("--pr")),
                        ("--deps", ",".join(blockers)), ("--metadata", meta and json.dumps(meta))):
        cmd += [flag, value] if value else []
    cmd += ["--description=" + body] if body else []
    cmd += ["-l", "project:" + found["--repo"]] if "--repo" in found else []
    bd(*cmd)
    named = [found[f] if f == "--kind" else "repo " + found[f] for f in ("--kind", "--repo") if f in found]
    line = "added %s%s -> Queued" % (ident, " (%s)" % ", ".join(named) if named else "")
    respond(found, "add", ident, line, tips)


def update(args):
    found, ids = view.flags(args, FIELDS + ("--title",), ("--json",))
    if len(ids) != 1:
        view.refuse("Expected 1 positional argument, got %d" % len(ids), "usage: tasks-axi update <id> [flags]")
    ident = ids[0]
    items = rows()
    row = target(items, ident)
    item = view.task(row, items)
    if not set(found) - {"--json"}:
        view.refuse("Nothing to update", "Pass a field, e.g. --title, --body, --body-file, --repo, or --kind")
    body = checked(found)
    words, cmd = links(row, found)
    title = " ".join([found.get("--title", item["title"]), *words])
    changed = []
    if title != item["title"]:
        cmd.append("--title=" + title)
    if found.get("--title", item["title"]) != item["title"]:
        changed.append("title")
    if body is not None and body != item["body"]:
        cmd.append("--description=" + body)
        changed.append("body")
    if found.get("--repo", item["repo"]) != item["repo"]:
        cmd += [] if item["repo"] == "-" else ["--remove-label", "project:" + item["repo"]]
        cmd += ["--add-label", "project:" + found["--repo"]]
        changed.append("repo")
    if found.get("--kind", item["kind"]) != item["kind"]:
        cmd += ["--set-metadata", "kind=" + found["--kind"]]
        changed.append("kind")
    if found.get("--priority", str(item["priority"])) != str(item["priority"]):
        cmd += ["-p", found["--priority"]]
        changed.append("priority")
    if words:
        changed.append("links")
    tips = ["Run `tasks-axi show %s --full` to see the result" % ident]
    if not cmd:
        respond(found, "update", ident, "updated %s already" % ident, tips, already=True)
        return
    bd("update", ident, *cmd)
    respond(found, "update", ident, "updated %s (%s)" % (ident, ", ".join(changed)), tips, changed=changed)


def done(args):
    found, ids = view.flags(args, ("--pr", "--report", "--note", "--keep"), ("--no-prune", "--json"))
    if len(ids) != 1:
        view.refuse("Expected 1 positional argument, got %d" % len(ids), "usage: tasks-axi done <id> [flags]")
    ident = ids[0]
    checked(found)
    items = rows()
    row = target(items, ident)
    item = view.task(row, items)
    already = item["state"] == "done"
    words, cmd = links(row, found)
    if words:
        cmd.append("--title=" + " ".join([item["title"], *words]))
    note = found.get("--note")
    if note and note not in item["body"].split("\n"):
        cmd.append("--description=" + "\n".join(filter(None, [item["body"], note])))
    if cmd:
        bd("update", ident, *cmd)
    if not already:
        bd("close", ident, *(["--force"] if item["blocked"] == "yes" else []))
    tail = "".join(" (%s %s)" % (name, found["--" + name]) for name in ("pr", "report") if "--" + name in found)
    line = "done %s%s -> Done%s" % (ident, " already" if already else "", tail)
    tips = ["Run `tasks-axi ready` to dispatch work unblocked by this"]
    extra = {"already": True} if already else {}
    respond(found, "done", ident, line, tips, card=False, **extra, pruned=0)


def block(args):
    found, ids = view.flags(args, ("--by",), ("--json",))
    if len(ids) != 1:
        view.refuse("Expected 1 positional argument, got %d" % len(ids), "usage: tasks-axi block <id> --by <other>")
    ident, other = ids[0], found.get("--by")
    if not other:
        view.refuse("--by <id> is required", "Name the other task, e.g. `--by treehouse-lease-t4`")
    items = rows()
    item = view.task(target(items, ident), items)
    if ident == other:
        view.refuse("A task cannot block itself")
    blocker(items, other)
    already = "blocked-by:" + other in item["deps"].split(",")
    if not already:
        bd("dep", "add", ident, other)
    tips = ["Run `tasks-axi unblock %s --by <other>` to clear it" % ident,
            "Run `tasks-axi ready` to see what is still dispatchable"]
    line = "block %s %s %s" % (ident, "already blocked-by" if already else "-> blocked-by", other)
    extra = {"already": True} if already else {}
    respond(found, "block", ident, line, tips, card=False, **extra, blocked_by=other)


def main():
    verb = sys.argv[1] if len(sys.argv) > 1 else ""
    serve = {"add": add, "create": add, "update": update, "edit": update, "done": done, "close": done,
             "block": block}.get(verb)
    if serve is None:
        view.refuse("Unknown write verb: " + verb)
    serve(sys.argv[2:])


if __name__ == "__main__":
    main()
