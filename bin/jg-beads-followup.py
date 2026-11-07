#!/usr/bin/env python3
"""jg-beads-followup.py - keep a public follow-up as one native Beads row.

Usage: BEADS_DIR=<store> jg-beads-write.py public-followup <add|list> [args...] [--json]

--json carries the public_followup payload bin/jg-public-followup.sh reads, one contract on either backlog.
The row has the public-followup label; metadata.followup holds what never changes, metadata.delivery_state where it stands.
One flock beside the store spans add's read, check and create, so a rerun answers already and a crash releases it.
"""
import datetime
import fcntl
import json
import os
import re
import secrets
import sys

sys.dont_write_bytecode = True
view = __import__("jg-beads-view")
write = __import__("jg-beads-write")

KIND = "public-followup"
PURPOSES = ("promised-final", "correction", "investigation-result", "milestone")
STATES = ("intent", "pending-work", "ready", "preflight-matched", "delivery-registered", "delivery-posting",
          "context-blocked", "retry-due", "unknown", "partial", "posted", "expired-action-required", "waived")
DELIVERABLES = {"pr-merged": ["pr_url"], "report-ready": ["report_path"], "local-main": ["commit_sha"],
                "failure-outcome": ["error_code"], "explicit-answer": []}
TASK_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
RFC3339 = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})\Z")


def bad(message):
    view.refuse(message, "Repair the typed public-followup data before retrying")


def record(value, path, keys):
    if not isinstance(value, dict):
        bad(path + " must be an object")
    for key in [k for k in keys if k not in value] + [k for k in value if k not in keys]:
        bad("%s.%s %s" % (path, key, "is required" if key in keys else "is not allowed"))
    return value


def matching(value, pattern, path, wanted):
    if not isinstance(value, str):
        bad(path + " must be a string")
    if not re.match(pattern, value):
        bad("%s %s" % (path, wanted))
    return value


def one_of(value, allowed, path):
    if not isinstance(value, str) or value not in allowed:
        bad("%s must be one of %s" % (path, ", ".join(allowed)))
    return value


def safe_text(value, path, limit):
    matching(value, "", path, "")
    if not value.strip():
        bad(path + " must not be empty")
    if value != value.strip():
        bad(path + " must not have leading or trailing whitespace")
    if len(value) > limit:
        bad("%s must be at most %d characters" % (path, limit))
    if any(ord(c) < 0x20 or ord(c) == 0x7F or 0xD800 <= ord(c) <= 0xDFFF for c in value):
        bad(path + " must be safe single-line text")
    return value


def moment(value, path):
    matching(value, RFC3339, path, "must be RFC3339")
    try:
        datetime.datetime.fromisoformat(re.sub(r"\.[0-9]+", "", value).replace("Z", "+00:00"))
    except ValueError:
        bad(path + " must be RFC3339")
    return value


def request_of(value, path="request"):
    record(value, path, ("request_id", "platform", "context_binding", "public_safe_summary", "received_at",
                         "followup_expires_at", "reservation_expires_at"))
    binding = record(value["context_binding"], path + ".context_binding", ("version", "value"))
    matching(binding["version"], r"ctx1\Z", path + ".context_binding.version", "must be ctx1")
    matching(binding["value"], r"ctx1_[A-Za-z0-9_-]+\Z", path + ".context_binding.value", "must start with ctx1_")
    matching(value["request_id"], r"req-[A-Za-z0-9._-]+\Z", path + ".request_id", "must start with req-")
    one_of(value["platform"], ("x", "discord"), path + ".platform")
    safe_text(value["public_safe_summary"], path + ".public_safe_summary", 240)
    for name in ("received_at", "followup_expires_at", "reservation_expires_at"):
        moment(value[name], "%s.%s" % (path, name))
    return value


def expected_of(value, path="expected_final"):
    record(value, path, ("type", "project", "required_deliverables", "completion_policy"))
    allowed = DELIVERABLES[one_of(value["type"], tuple(DELIVERABLES), path + ".type")]
    if value["project"] is not None:
        matching(value["project"], r"[A-Za-z0-9][A-Za-z0-9._/-]{0,79}\Z", path + ".project", "is invalid")
    wanted = value["required_deliverables"]
    if not isinstance(wanted, list):
        bad(path + ".required_deliverables must be an array")
    for index, name in enumerate(wanted):
        matching(name, r"[a-z][a-z0-9_]{0,63}\Z", "%s.required_deliverables[%d]" % (path, index), "is invalid")
        if name not in allowed:
            bad("%s.%s is not valid for expected type %s" % (path, name, value["type"]))
    if len(set(wanted)) != len(wanted):
        bad(path + ".required_deliverables must not contain duplicates")
    one_of(value["completion_policy"], ("all-required", "any-required"), path + ".completion_policy")
    return value


def loaded(found, name):
    path = found.get(name) or view.refuse(name + " <file> is required")
    try:
        with open(path, "rb") as source:
            raw = source.read(1000001)
    except OSError:
        view.refuse("Could not read %s path: %s" % (name, path))
    if len(raw) > 1000000:
        view.refuse(name + " is too large")
    try:
        return json.loads(raw.decode("utf-8"))
    except ValueError:
        view.refuse(name + " must contain valid JSON")


def promised(row):
    return "followup" in (row.get("metadata") or {})


def typed(row, items):
    meta = row["metadata"]
    fixed = meta["followup"]
    delivery = {"state": meta["delivery_state"], "delivery_key": fixed["delivery_key"], "attempt_count": 0, **dict.fromkeys(
        ("payload_digest", "last_error_code", "next_attempt_at", "receipt", "last_error", "waiver"))}
    return {**write.as_json(view.task(row, items)), "priority": None, "public_followup": {
        "schema_version": 1, "revision": meta["revision"], "request": fixed["request"], "purpose": fixed["purpose"],
        "expected_final": fixed["expected_final"], "obligation_expires_at": fixed["obligation_expires_at"],
        "delivery": delivery, "work_relations": [],
        "lineage": {"predecessor_obligation_id": None, "successor_obligation_id": None}}}


def answer(found, ident, changed, already=False):
    items = write.rows()
    task = typed(items[ident], items)
    state, revision = task["public_followup"]["delivery"]["state"], task["public_followup"]["revision"]
    if "--json" in found:
        print(json.dumps({"ok": True, "action": "public-followup.add", **({"already": True} if already else {}),
                          "revision": revision, "changed": changed, "task": task}, indent=2))
        return
    print("ok: public-followup add %s%s -> %s (revision %d)" % (ident, " already" if already else "", state, revision))
    print("already: true\n" if already else "", end="")
    print("public_followup:\n  id: %s\n  state: %s\n  delivery_state: %s\n  revision: %d\n  relations: 0" % (
        ident, task["state"], state, revision))
    print("help[1]:\n  - Run `tasks-axi public-followup list --work-ref <home/task>` to reconcile related work")


def add(args):
    found, ids = view.flags(args, ("--request-context-file", "--purpose", "--expected-final-file", "--expires-at"), ("--json",))
    if len(ids) != 1 or not TASK_ID.match(ids[0]):
        view.refuse("add needs one task id", "usage: tasks-axi public-followup add <id> [flags]")
    fixed = {"request": request_of(loaded(found, "--request-context-file")),
             "purpose": one_of(found.get("--purpose"), PURPOSES, "--purpose"),
             "expected_final": expected_of(loaded(found, "--expected-final-file")),
             "obligation_expires_at": moment(found.get("--expires-at"), "--expires-at")}
    row = write.rows().get(ids[0])
    if row and not promised(row):
        view.refuse('Task "%s" already exists' % ids[0], None, "CONFLICT", 1)
    if row and {name: row["metadata"]["followup"][name] for name in fixed} != fixed:
        view.refuse('Public-followup "%s" already exists with different immutable data' % ids[0], None, "CONFLICT", 1)
    if not row:
        meta = {"kind": KIND, "followup": {**fixed, "delivery_key": "fd1_" + secrets.token_urlsafe(24)},
                "delivery_state": "intent", "revision": 1}
        write.bd("create", "--title=" + fixed["request"]["public_safe_summary"], "--id", ids[0], "--force",
                 "--labels", KIND, "--metadata", json.dumps(meta))
    answer(found, ids[0], [] if row else ["task", "public_followup"], bool(row))


def listing(args):
    found, ids = view.flags(args, ("--delivery-state",), ("--json",))
    if ids:
        view.refuse("list takes no id", "usage: tasks-axi public-followup list [flags]")
    state = found.get("--delivery-state")
    if state is not None and state not in STATES:
        view.refuse("--delivery-state must be one of " + ", ".join(STATES))
    items = write.rows()
    kept = [row for row in items.values() if promised(row) and state in (None, row["metadata"]["delivery_state"])]
    if "--json" in found:
        print(json.dumps({"ok": True, "action": "public-followup.list", "count": len(kept),
                          "public_followups": [typed(row, items) for row in kept]}, indent=2))
        return
    print("count: %d" % len(kept))
    if kept:
        view.table("public_followups", [view.task(row, items) for row in kept], view.ROW + ["delivery_state"])
    else:
        print("public_followups: 0 obligations found")


def main(args):
    verb = args[0] if args else ""
    if verb == "list":
        listing(args[1:])
    elif verb == "add":
        env = os.path.join(os.path.dirname(os.environ["BEADS_DIR"]), ".jg-beads-env")
        os.makedirs(env, exist_ok=True)
        with open(os.path.join(env, "followup.lock"), "w", encoding="utf-8") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            add(args[1:])
    else:
        view.refuse("Unknown public-followup command: " + verb if verb else "Missing public-followup command",
                    "usage: tasks-axi public-followup <command> [args] [flags]")
