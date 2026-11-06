#!/usr/bin/env python3
"""jg-beads-write.py - serve tasks-axi's add on a Beads store.

Usage: BEADS_DIR=<store> jg-beads-write.py <add|create> [args...]

bin/jg-tasks-axi-lib.sh's jg_backlog_beads_write starts it after bin/jg-tasks-axi.sh's intake and captain guards.
Every bd call goes through bin/jg-beads.sh. Replies and refusals print tasks-axi's lines on stdout.
kind is metadata.kind, repo is the project:<repo> label, the first PR is external_ref, later ones are metadata.prs,
and reports are metadata.reports, each comma-joined; a PR or report also joins the title, as tasks-axi writes it.
A rerun converges: an existing id is left alone. bd refuses an id with no dash, and that refusal reaches stderr with
bd's exit status.
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


def respond(found, action, ident, line, tips, **extra):
    items = rows()
    item = view.task(items[ident], items)
    if "--json" in found:
        print(json.dumps({"ok": True, "action": action, **extra, "task": as_json(item)}, indent=2))
        return
    print("ok: " + line)
    if extra.get("already"):
        print("already: true")
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


def main():
    verb = sys.argv[1] if len(sys.argv) > 1 else ""
    if verb not in ("add", "create"):
        view.refuse("Unknown write verb: " + verb)
    add(sys.argv[2:])


if __name__ == "__main__":
    main()
