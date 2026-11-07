#!/usr/bin/env python3
"""jg-beads-followup.py - keep a public follow-up as one native Beads row.

Usage: BEADS_DIR=<store> jg-beads-write.py public-followup <add|bind-work|supersede-work|work-event|begin-delivery|record-delivery|record-error|waive|list|ready> [args...] [--json]

--json carries the public_followup payload bin/jg-public-followup.sh reads, one contract on either backlog.
The row has the public-followup label; metadata.followup holds what never changes, metadata.relations the bound work.
Each accepted work event is one comment, the record of what landed; metadata.delivery_state is the cached answer.
A tracks edge joins the row to bound work in this store, and never blocks it; work in another home stays metadata.
Every event comment comes after its checks and before the row write, so a rerun after a crash folds the comment and converges.
Status is the delivery lock: an attempt is one update guarded by --if-status, so a losing writer exits 13 and nothing posts.
metadata.delivery holds the attempt, and each delivery record is one comment after its row write, which a rerun fills in once.
One flock beside the store spans each change's read, check and write, and a crash releases it.
"""
import datetime
import fcntl
import json
import os
import re
import secrets
import sys
import time

sys.dont_write_bytecode = True
view = __import__("jg-beads-view")
write = __import__("jg-beads-write")

KIND = "public-followup"
PURPOSES = ("promised-final", "correction", "investigation-result", "milestone")
STATES = ("intent", "pending-work", "ready", "preflight-matched", "delivery-registered", "delivery-posting",
          "context-blocked", "retry-due", "unknown", "partial", "posted", "expired-action-required", "waived")
DELIVERABLES = {"pr-merged": ["pr_url"], "report-ready": ["report_path"], "local-main": ["commit_sha"],
                "failure-outcome": ["error_code"], "explicit-answer": []}
MUTABLE = ("intent", "pending-work", "ready")
POSTING, FINAL = ("delivery-posting", "unknown", "partial"), ("posted", "waived")
FAULTS = ("context-blocked", "retry-due", "unknown", "partial", "expired-action-required")
DELIVERY = ("attempt_count", "payload_digest", "last_error_code", "next_attempt_at", "receipt", "last_error", "waiver")
CLEARED = dict.fromkeys(("last_error_code", "next_attempt_at", "last_error"))
RELATION = ("relation_id", "work_ref", "role", "required", "generation")
EVENT = ("schema_version", "event_id", "obligation_id", "relation_id", "generation", "source_home_id", "work_id",
         "outcome_type", "deliverables", "public_safe_outcome", "occurred_at")
USAGE = {"bind-work": "bind-work <id> --relation-file <file> [--json]",
         "supersede-work": "supersede-work <id> --relation <relation-id> --successor-file <file> [--json]",
         "work-event": "work-event <id> --event-file <file> [--json]",
         "begin-delivery": "begin-delivery <id> --payload-hash <sha256> [--json]",
         "record-delivery": "record-delivery <id> --receipt-file <file> [--json]",
         "record-error": "record-error <id> --error-file <file> [--json]",
         "waive": "waive <id> --reason <text> --approved-by captain [--json]"}
LABEL = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
PR_URL = re.compile(r"https://(%s(?:\.%s)*)/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/(pull|pulls)/[1-9][0-9]*\Z" % (LABEL, LABEL))
WORK_CHANGED = ["work_relations", "delivery.state"]
TASK_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
RFC3339 = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})\Z")


def bad(message):
    view.refuse(message, "Repair the typed public-followup data before retrying")


def record(value, path, keys, optional=()):
    if not isinstance(value, dict):
        bad(path + " must be an object")
    for key in [k for k in keys if k not in value] + [k for k in value if k not in keys and k not in optional]:
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


def home_of(value, path):
    wire = os.environ["JG_BEADS_WIRE_LEAD"]
    return matching(value, r"(main|%s[A-Za-z0-9][A-Za-z0-9._-]*)\Z" % re.escape(wire), path, "must be main or %s<stable-id>" % wire)


def integer(value, path, least=1):
    if type(value) is not int or value < least:
        bad("%s must be an integer >= %d" % (path, least))
    return value


def relation_of(value, path="relation"):
    record(value, path, RELATION)
    matching(value["relation_id"], r"rel-[A-Za-z0-9._-]+\Z", path + ".relation_id", "must start with rel-")
    ref = record(value["work_ref"], path + ".work_ref", ("home_id", "task_id"))
    home_of(ref["home_id"], path + ".work_ref.home_id")
    matching(ref["task_id"], TASK_ID, path + ".work_ref.task_id", "must be a task id")
    one_of(value["role"], ("fulfills", "contributes"), path + ".role")
    if not isinstance(value["required"], bool):
        bad(path + ".required must be a boolean")
    integer(value["generation"], path + ".generation")
    return value


def event_of(value, path="event"):
    if not isinstance(value, dict):
        bad(path + " must be an object")
    event = record({key: item for key, item in value.items() if key != "successor"}, path, EVENT)
    if event["schema_version"] != 1:
        bad(path + ".schema_version must be 1")
    matching(event["event_id"], r"[A-Za-z0-9][A-Za-z0-9._:-]{0,159}\Z", path + ".event_id", "must be a stable event id")
    matching(event["obligation_id"], TASK_ID, path + ".obligation_id", "must be a task id")
    matching(event["relation_id"], r"rel-[A-Za-z0-9._-]+\Z", path + ".relation_id", "must start with rel-")
    integer(event["generation"], path + ".generation")
    home_of(event["source_home_id"], path + ".source_home_id")
    matching(event["work_id"], TASK_ID, path + ".work_id", "must be a task id")
    one_of(event["outcome_type"], ("pr-merged", "report-ready", "local-main", "failed", "superseded"), path + ".outcome_type")
    for name, text in record(event["deliverables"], path + ".deliverables", event["deliverables"]).items():
        matching(name, r"[a-z][a-z0-9_]{0,63}\Z", "%s.deliverables.%s" % (path, name), "has an invalid deliverable name")
        safe_text(text, "%s.deliverables.%s" % (path, name), 500)
    safe_text(event["public_safe_outcome"], path + ".public_safe_outcome", 240)
    moment(event["occurred_at"], path + ".occurred_at")
    if "successor" not in value:
        bad(path + ".successor is required")
    return event, None if value["successor"] is None else relation_of(value["successor"], path + ".successor")


def versioned(value, path):
    if value.get("schema_version", 1) != 1:
        bad(path + ".schema_version must be 1")


def later(value, path):
    return None if value is None else moment(value, path)


def receipt_of(value, path="receipt"):
    record(value, path, ("state", "request_id", "platform", "attempt_count", "total_chunks", "posted_chunks", "posted_at"),
           ("schema_version", "retain_until"))
    versioned(value, path)
    if value["state"] != "posted":
        bad(path + ".state must be posted")
    total = integer(value["total_chunks"], path + ".total_chunks")
    if integer(value["posted_chunks"], path + ".posted_chunks") != total:
        bad(path + ".posted_chunks must equal total_chunks for posted")
    matching(value["request_id"], r"req-[A-Za-z0-9._-]+\Z", path + ".request_id", "must start with req-")
    one_of(value["platform"], ("x", "discord"), path + ".platform")
    integer(value["attempt_count"], path + ".attempt_count")
    moment(value["posted_at"], path + ".posted_at")
    return {**value, "schema_version": 1, "retain_until": later(value.get("retain_until"), path + ".retain_until")}


def fault_of(value, path="error"):
    record(value, path, ("state", "attempt_count", "error_code", "occurred_at"),
           ("schema_version", "next_attempt_at", "total_chunks", "posted_chunks"))
    versioned(value, path)
    matching(value["error_code"], r"[a-z][a-z0-9._-]{0,63}\Z", path + ".error_code", "must be a safe error enum")
    one_of(value["state"], FAULTS, path + ".state")
    total, posted = value.get("total_chunks"), value.get("posted_chunks")
    total = total if total is None else integer(total, path + ".total_chunks", 0)
    posted = posted if posted is None else integer(posted, path + ".posted_chunks", 0)
    if (total is None) != (posted is None):
        bad(path + " chunk counts must both be present or both be null")
    if value["state"] == "partial" and (total is None or total < 2 or posted < 1 or posted >= total):
        bad(path + " partial state requires 0 < posted_chunks < total_chunks")
    integer(value["attempt_count"], path + ".attempt_count", 0)
    moment(value["occurred_at"], path + ".occurred_at")
    return {**value, "schema_version": 1, "next_attempt_at": later(value.get("next_attempt_at"), path + ".next_attempt_at"),
            "total_chunks": total, "posted_chunks": posted}


def pull_request(url):
    found = PR_URL.match(url)
    return found and not {".", ".."} & set(found.group(2, 3)) and (found[4] == "pull") == (found[1] == "github.com")


SHAPES = {"pr_url": pull_request, "report_path": re.compile(r"data/[A-Za-z0-9][A-Za-z0-9._-]*/report\.md\Z").match,
          "commit_sha": re.compile(r"[a-f0-9]{7,64}\Z").match, "error_code": re.compile(r"[a-z][a-z0-9._-]{0,63}\Z").match}


def failure_safe(items):
    return len(items) <= 1 and all(name == "error_code" and SHAPES[name](text) for name, text in items.items())


def meets(event, expected):
    outcome = {"failure-outcome": "failed", "explicit-answer": "local-main"}.get(expected["type"], expected["type"])
    items = event["deliverables"]
    return (event["outcome_type"] == outcome and all(name in DELIVERABLES[expected["type"]] and SHAPES[name](text)
                                                     for name, text in items.items())
            and all(name in items for name in expected["required_deliverables"]))


def contract(event, successor, expected):
    if event["outcome_type"] == "superseded":
        if successor is None:
            bad("superseded work event requires successor")
        if event["deliverables"]:
            bad("superseded work event cannot carry deliverables")
    elif successor is not None:
        bad("only a superseded work event may carry successor")
    elif event["outcome_type"] == "failed" and expected["type"] != "failure-outcome":
        if not failure_safe(event["deliverables"]):
            bad("failed work event has unsafe deliverables")
    elif not meets(event, expected):
        bad("work event does not satisfy expected outcome and deliverables")


def settled(relation, expected):
    last = relation["accepted_events"][-1] if relation["accepted_events"] else None
    if last is None or relation["state"] not in ("landed", "failed"):
        return False
    if relation["state"] == "landed" or expected["type"] == "failure-outcome":
        return meets(last, expected)
    return last["outcome_type"] == "failed" and failure_safe(last["deliverables"])


def is_ready(relations, expected, policy):
    active = [item for item in relations if item["state"] != "superseded"]
    fulfilling = [item for item in active if item["role"] == "fulfills"]
    if not fulfilling or not all(settled(item, expected) for item in active if item["required"]):
        return False
    return (all if policy == "all-required" else any)(settled(item, expected) for item in fulfilling)


def standing(meta, relations):
    if meta["delivery_state"] not in MUTABLE:
        return meta["delivery_state"]
    expected = meta["followup"]["expected_final"]
    return "ready" if is_ready(relations, expected, expected["completion_policy"]) else "pending-work" if relations else "intent"


def fresh(relation):
    return {**relation, "state": "bound", "successor_relation_id": None, "accepted_event_ids": [], "accepted_events": []}


def named(relations, ident):
    return next((item for item in relations if item["relation_id"] == ident), None)


def replace(relations, previous, successor):
    previous.update(state="superseded", successor_relation_id=successor["relation_id"])
    if not named(relations, successor["relation_id"]):
        relations.append(fresh(successor))


def landing(relations, event, successor):
    relation = named(relations, event["relation_id"])
    if relation is None:
        return
    relation["accepted_event_ids"].append(event["event_id"])
    relation["accepted_events"].append(event)
    if event["outcome_type"] == "superseded":
        replace(relations, relation, successor)
    else:
        relation["state"] = "failed" if event["outcome_type"] == "failed" else "landed"


def notes(row):
    return json.loads(write.bd("comments", row["id"], "--json")) if row.get("comment_count") else []


def fold(row):
    relations = [{**item, "accepted_event_ids": [], "accepted_events": []} for item in row["metadata"].get("relations", [])]
    for note in notes(row):
        try:
            item = json.loads(note["text"])
        except ValueError:
            continue
        if isinstance(item, dict) and item.get("followup") == "work-event":
            landing(relations, {key: item[key] for key in EVENT}, item["successor"])
    return relations


def commit(row, relations):
    meta = row["metadata"]
    kept = [{key: value for key, value in item.items() if not key.startswith("accepted_")} for item in relations]
    write.bd("update", row["id"], "--if-status", "open", "--metadata", json.dumps(
        {"relations": kept, "delivery_state": standing(meta, relations), "revision": meta["revision"] + 1}))


def delivery_of(row, relations):
    meta = row["metadata"]
    return {"state": standing(meta, relations), "delivery_key": meta["followup"]["delivery_key"], "attempt_count": 0,
            **dict.fromkeys(DELIVERY[1:]), **meta.get("delivery", {})}


def logged(row, delivery):
    text = json.dumps({"followup": "delivery", **{key: delivery[key] for key in ("state",) + DELIVERY}}, sort_keys=True)
    if text not in [note["text"] for note in notes(row)]:
        write.bd("comment", row["id"], text)


def settle(row, past, state, **changes):
    """Move the delivery in one guarded row write, which a stale reader loses with exit 13, then log the record."""
    meta, kept = row["metadata"], {**past, "state": state, **changes}
    status = "closed" if state in FINAL else "in_progress" if state in POSTING else "open"
    write.bd("update", row["id"], "--if-status", row["status"], "--status", status, *["--force"] * (status == "closed"),
             "--metadata", json.dumps({"delivery_state": state, "delivery": {key: kept[key] for key in DELIVERY},
                                       "revision": meta["revision"] + 1, **({"closed_ns": time.time_ns()} if status == "closed" else {})}))
    logged(row, kept)


def identity(relation):
    return {key: relation[key] for key in RELATION}


def clash(message):
    view.refuse(message, None, "CONFLICT", 1)


def one_id(ids, verb):
    if len(ids) != 1:
        view.refuse("Expected 1 positional argument, got %d" % len(ids), "usage: tasks-axi public-followup " + USAGE[verb])
    return ids[0]


def obligation(ident):
    items = write.rows()
    row = write.target(items, ident)
    if not promised(row):
        view.refuse('Task "%s" is not a public-followup obligation' % ident)
    return items, row, fold(row)


def mutable(row, relations):
    state = standing(row["metadata"], relations)
    if state not in MUTABLE:
        view.refuse("Work relations cannot change in delivery state " + state)


def track(items, ident, relation):
    ref = relation["work_ref"]
    if ref["home_id"] == os.environ["JG_BEADS_HOME_ID"] and ref["task_id"] in items and ref["task_id"] != ident:
        write.bd("dep", "add", ident, ref["task_id"], "--type", "tracks")


def succeeding(relations, previous, successor):
    if successor["relation_id"] == previous["relation_id"]:
        view.refuse("Successor relation id must differ from its predecessor")
    if successor["generation"] != previous["generation"] + 1:
        view.refuse("Successor generation must be %d" % (previous["generation"] + 1))
    if named(relations, successor["relation_id"]):
        clash('Successor relation "%s" already exists' % successor["relation_id"])


def promised(row):
    return "followup" in (row.get("metadata") or {})


def typed(row, items):
    meta = row["metadata"]
    fixed = meta["followup"]
    relations = fold(row)
    return {**write.as_json(view.task(row, items)), "priority": None, "public_followup": {
        "schema_version": 1, "revision": meta["revision"], "request": fixed["request"], "purpose": fixed["purpose"],
        "expected_final": fixed["expected_final"], "obligation_expires_at": fixed["obligation_expires_at"],
        "delivery": delivery_of(row, relations), "work_relations": relations,
        "lineage": {"predecessor_obligation_id": None, "successor_obligation_id": None}}}


def answer(found, verb, ident, changed, already=False):
    items = write.rows()
    task = typed(items[ident], items)
    state, revision = task["public_followup"]["delivery"]["state"], task["public_followup"]["revision"]
    if "--json" in found:
        print(json.dumps({"ok": True, "action": "public-followup." + verb, **({"already": True} if already else {}),
                          "revision": revision, "changed": changed, **({"pruned": 0} if verb in ("record-delivery", "waive") else {}),
                          "task": task}, indent=2))
        return
    print("ok: public-followup %s %s%s -> %s (revision %d)" % (verb, ident, " already" if already else "", state, revision))
    print("already: true\n" if already else "", end="")
    print("public_followup:\n  id: %s\n  state: %s\n  delivery_state: %s\n  revision: %d\n  relations: %d" % (
        ident, task["state"], state, revision, len(task["public_followup"]["work_relations"])))
    if state not in FINAL:
        print("help[1]:\n  - Run `tasks-axi public-followup %s" % (
            "begin-delivery %s --payload-hash <sha256>` after semantic preflight" % ident if state == "ready" else
            "record-delivery %s --receipt-file <file>` after receipt reconciliation" % ident if state in POSTING else
            "list --work-ref <home/task>` to reconcile related work"))


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
                "delivery_state": "intent", "revision": 1, "added_ns": time.time_ns()}
        write.bd("create", "--title=" + fixed["request"]["public_safe_summary"], "--id", ids[0], "--force",
                 "--labels", KIND, "--metadata", json.dumps(meta))
    answer(found, "add", ids[0], [] if row else ["task", "public_followup"], bool(row))


def bind(args):
    found, ids = view.flags(args, ("--relation-file",), ("--json",))
    relation = relation_of(loaded(found, "--relation-file"))
    ident = one_id(ids, "bind-work")
    if relation["generation"] != 1:
        view.refuse("A newly bound work relation must start at generation 1")
    items, row, relations = obligation(ident)
    known = named(relations, relation["relation_id"])
    if known and identity(known) != identity(relation):
        clash('Relation "%s" already exists with different identity' % relation["relation_id"])
    if not known:
        mutable(row, relations)
        track(items, ident, relation)
        commit(row, relations + [fresh(relation)])
    answer(found, "bind-work", ident, [] if known else WORK_CHANGED, bool(known))


def needed(found, name):
    value = found.get(name)
    if value is None:
        view.refuse(name + " <value> is required", "Pass %s=<value>" % name)
    if not value.strip():
        view.refuse(name + " requires a value", "Pass %s=... with a non-empty value" % name)
    if "\n" in value or "\r" in value:
        view.refuse(name + " must be a single line", "Pass %s=... without line breaks" % name)
    return value


def supersede(args):
    found, ids = view.flags(args, ("--relation", "--successor-file"), ("--json",))
    ref = needed(found, "--relation")
    successor = relation_of(loaded(found, "--successor-file"))
    ident = one_id(ids, "supersede-work")
    items, row, relations = obligation(ident)
    previous = named(relations, ref) or view.refuse('Relation "%s" not found' % ref)
    if previous["state"] == "superseded":
        existing = named(relations, previous["successor_relation_id"])
        if not existing or identity(existing) != identity(successor):
            clash('Relation "%s" already has a different successor' % ref)
        answer(found, "supersede-work", ident, [], True)
        return
    if previous["state"] == "landed":
        view.refuse('Landed relation "%s" cannot be superseded' % ref)
    mutable(row, relations)
    succeeding(relations, previous, successor)
    track(items, ident, successor)
    replace(relations, previous, successor)
    commit(row, relations)
    answer(found, "supersede-work", ident, WORK_CHANGED)


def repeated(found, ident, row, relations, event, successor):
    holder = next((item for item in relations if event["event_id"] in item["accepted_event_ids"]), None)
    if holder is None:
        return False
    prior = next(item for item in holder["accepted_events"] if item["event_id"] == event["event_id"])
    after = named(relations, holder["successor_relation_id"]) if holder["successor_relation_id"] else None
    same = (successor and after and identity(after) == identity(successor)) if prior["outcome_type"] == "superseded" else not successor
    if prior != event or not same:
        clash('Event id "%s" was already accepted with different data' % event["event_id"])
    if row["metadata"]["delivery_state"] != standing(row["metadata"], relations):
        commit(row, relations)
    answer(found, "work-event", ident, [], True)
    return True


def work_event(args):
    found, ids = view.flags(args, ("--event-file",), ("--json",))
    event, successor = event_of(loaded(found, "--event-file"))
    ident = one_id(ids, "work-event")
    if event["obligation_id"] != ident:
        view.refuse("Work event obligation_id does not match the command id")
    items, row, relations = obligation(ident)
    if repeated(found, ident, row, relations, event, successor):
        return
    mutable(row, relations)
    relation = named(relations, event["relation_id"]) or view.refuse('Unknown work relation "%s"' % event["relation_id"])
    if event["generation"] != relation["generation"] or relation["state"] == "superseded":
        view.refuse('Stale work event generation for relation "%s"' % event["relation_id"])
    if (event["source_home_id"], event["work_id"]) != (relation["work_ref"]["home_id"], relation["work_ref"]["task_id"]):
        view.refuse("Work event source home or task does not match the relation")
    if relation["state"] != "bound":
        clash('Relation "%s" already has a terminal work event' % event["relation_id"])
    contract(event, successor, row["metadata"]["followup"]["expected_final"])
    if successor:
        succeeding(relations, relation, successor)
        track(items, ident, successor)
    write.bd("comment", ident, json.dumps({"followup": "work-event", **event, "successor": successor}))
    landing(relations, event, successor)
    commit(row, relations)
    answer(found, "work-event", ident, WORK_CHANGED)


def begin(args):
    found, ids = view.flags(args, ("--payload-hash",), ("--json",))
    digest = matching(needed(found, "--payload-hash"), r"[a-f0-9]{64}\Z", "--payload-hash", "must be a lowercase SHA-256 hex digest")
    ident = one_id(ids, "begin-delivery")
    items, row, relations = obligation(ident)
    past = delivery_of(row, relations)
    if past["payload_digest"] not in (None, digest):
        clash("Delivery payload hash conflicts with the recorded digest")
    if past["state"] == "delivery-posting" and past["payload_digest"] == digest:
        logged(row, past)
        answer(found, "begin-delivery", ident, [], True)
        return
    if view.task(row, items)["blocked"] != "no":
        view.refuse("Cannot begin delivery while the obligation has an active blocker")
    if past["state"] not in ("ready", "preflight-matched", "delivery-registered", "retry-due"):
        view.refuse("Cannot begin delivery from state " + past["state"])
    settle(row, past, "delivery-posting", payload_digest=digest, attempt_count=past["attempt_count"] + 1, **CLEARED)
    answer(found, "begin-delivery", ident, ["delivery"])


def record_delivery(args):
    found, ids = view.flags(args, ("--receipt-file",), ("--json",))
    receipt = receipt_of(loaded(found, "--receipt-file"))
    ident = one_id(ids, "record-delivery")
    _, row, relations = obligation(ident)
    past, request = delivery_of(row, relations), row["metadata"]["followup"]["request"]
    if (receipt["request_id"], receipt["platform"]) != (request["request_id"], request["platform"]):
        view.refuse("Posted receipt request or platform does not match the obligation")
    if past["state"] == "posted":
        if past["receipt"] != receipt:
            clash("Public-followup already has a different posted receipt")
        logged(row, past)
        answer(found, "record-delivery", ident, [], True)
        return
    if past["state"] == "waived":
        clash("Waived public-followup cannot accept a delivery receipt")
    if past["payload_digest"] is None or past["attempt_count"] < 1 or receipt["attempt_count"] != past["attempt_count"]:
        view.refuse("Posted receipt does not match a recorded delivery attempt")
    if past["state"] not in ("delivery-posting", "retry-due", "unknown", "partial"):
        view.refuse("Cannot record delivery from state " + past["state"])
    settle(row, past, "posted", receipt=receipt, **CLEARED)
    answer(found, "record-delivery", ident, ["delivery", "state"])


def record_error(args):
    found, ids = view.flags(args, ("--error-file",), ("--json",))
    fault = fault_of(loaded(found, "--error-file"))
    ident = one_id(ids, "record-error")
    _, row, relations = obligation(ident)
    past = delivery_of(row, relations)
    state = past["state"]
    if state in FINAL:
        view.refuse("Completed public-followup cannot record a delivery error")
    if fault["attempt_count"] != past["attempt_count"]:
        view.refuse("Delivery error does not match the current recorded attempt")
    if state == fault["state"] and past["last_error"] == fault:
        logged(row, past)
        answer(found, "record-error", ident, [], True)
        return
    if state in ("intent", "pending-work"):
        view.refuse("Delivery errors cannot be recorded before work is ready")
    if fault["state"] in ("unknown", "partial") and (past["payload_digest"] is None or past["attempt_count"] < 1):
        view.refuse(fault["state"] + " requires a recorded delivery attempt")
    if state == "expired-action-required" and fault["state"] not in (state, "context-blocked"):
        bad("public_followup delivery cannot move from %s to %s" % (state, fault["state"]))
    settle(row, past, fault["state"], last_error_code=fault["error_code"], next_attempt_at=fault["next_attempt_at"], last_error=fault)
    answer(found, "record-error", ident, ["delivery"])


def waive(args):
    found, ids = view.flags(args, ("--reason", "--approved-by"), ("--json",))
    reason = needed(found, "--reason").strip()
    if not reason or len(reason) > 240 or any(ord(c) < 0x20 or ord(c) == 0x7F for c in reason):
        view.refuse("--reason must be safe single-line text up to 240 characters")
    if needed(found, "--approved-by") != "captain":
        view.refuse("--approved-by must be exactly captain")
    ident = one_id(ids, "waive")
    _, row, relations = obligation(ident)
    past = delivery_of(row, relations)
    if past["state"] == "waived":
        if past["waiver"]["reason"] != reason:
            clash("Public-followup already has a different waiver")
        logged(row, past)
        answer(found, "waive", ident, [], True)
        return
    if past["state"] == "posted":
        clash("Posted public-followup cannot be waived")
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    settle(row, past, "waived", waiver={"approved_by": "captain", "reason": reason, "waived_at": stamp}, **CLEARED)
    answer(found, "waive", ident, ["delivery", "state"])


def promises(items):
    # bd stamps to the second, so the row's own stamps keep two promises of one second in order: open first, newest closed next.
    def place(row):
        meta = row["metadata"]
        return (1, -meta.get("closed_ns", 0), row["created_at"]) if row["status"] == "closed" else (0, meta.get("added_ns", 0), row["created_at"])

    return [typed(row, items) for row in sorted(filter(promised, items.values()), key=place)]


def shown(found, name, action, items, kept, none):
    if "--json" in found:
        print(json.dumps({"ok": True, "action": "public-followup." + action, "count": len(kept), name: kept}, indent=2))
        return
    print("count: %d" % len(kept))
    if kept:
        view.table(name, [{**view.task(items[item["id"]], items), "delivery_state": item["public_followup"]["delivery"]["state"]}
                          for item in kept], view.ROW + ["delivery_state"])
    else:
        print(none)


def listing(args):
    found, ids = view.flags(args, ("--delivery-state", "--work-ref"), ("--json",))
    if ids:
        view.refuse("list takes no id", "usage: tasks-axi public-followup list [flags]")
    state = found.get("--delivery-state")
    if state is not None and state not in STATES:
        view.refuse("--delivery-state must be one of " + ", ".join(STATES))
    ref = found.get("--work-ref")
    wire = re.escape(os.environ["JG_BEADS_WIRE_LEAD"])
    if ref is not None and not re.match(r"(main|%s[A-Za-z0-9][A-Za-z0-9._-]*)/[A-Za-z0-9][A-Za-z0-9._-]*\Z" % wire, ref):
        view.refuse("--work-ref must be <home-id>/<task-id>")
    items = write.rows()
    kept = promises(items)
    kept = [item for item in kept if state in (None, item["public_followup"]["delivery"]["state"]) and (
        ref is None or ref in ["%(home_id)s/%(task_id)s" % rel["work_ref"] for rel in item["public_followup"]["work_relations"]])]
    shown(found, "public_followups", "list", items, kept, "public_followups: 0 obligations found")


def owed(args):
    found, ids = view.flags(args, (), ("--json",))
    if ids:
        view.refuse("Expected no positional arguments, got %d" % len(ids), "usage: tasks-axi public-followup ready [--json]")
    items = write.rows()
    kept = promises(items)
    kept = [item for item in kept if item["public_followup"]["delivery"]["state"] == "ready" and item["state"] != "done"
            and view.task(items[item["id"]], items)["blocked"] == "no"]
    shown(found, "ready_public_followups", "ready", items, kept, "ready_public_followups: 0 delivery-ready obligations")
    if kept and "--json" not in found:
        print("help[1]:\n  - Run `tasks-axi public-followup begin-delivery <id> --payload-hash <sha256>` after semantic preflight")


def main(args):
    verb = args[0] if args else ""
    changes = {"add": add, "bind-work": bind, "supersede-work": supersede, "work-event": work_event, "begin-delivery": begin,
               "record-delivery": record_delivery, "record-error": record_error, "waive": waive}
    if verb in ("list", "ready"):
        (listing if verb == "list" else owed)(args[1:])
    elif verb in changes:
        env = os.path.join(os.path.dirname(os.environ["BEADS_DIR"]), ".jg-beads-env")
        os.makedirs(env, exist_ok=True)
        with open(os.path.join(env, "followup.lock"), "w", encoding="utf-8") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            changes[verb](args[1:])
    else:
        view.refuse("Unknown public-followup command: " + verb if verb else "Missing public-followup command",
                    "usage: tasks-axi public-followup <command> [args] [flags]")
