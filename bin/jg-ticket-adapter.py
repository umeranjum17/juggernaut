#!/usr/bin/env python3
"""jg-ticket-adapter.py - the Beads adapter for the board's ticket interface v1 (sign-off docs/ticket-adapter.md).

Usage: BEADS_DIR=<store>/.beads jg-ticket-adapter.py <describe|list|get|create|update|history|comment>   (one JSON request on stdin)

One JSON response on stdout and nothing else: exit 0 with the answer, exit 1 with {"error": {...}}. It reaches the store only through
bin/jg-beads.sh (JG_BEADS_SH names another wrapper) and bin/jg-beads-read.py, whose facts are in data/ta-j1-beads-facts/facts.md.
The ticket is bd's own row: `id`, `status`, `assignee` and `parent` are bd's words, `kind` is bd's issue type, `body` its description,
`labels` and `links` (its outgoing edges other than the parent) as bd keeps them. With JG_HOME and a configured fleet, list derives board status and project from the homes and uses home-qualified ids. It reads each home's store with one
`jg-beads-read.py board` query (bd list and bd show took minutes on a store of thousands of rows), skips a home that names no store, fails when a store it names cannot be read,
and answers a client that names no limit with pages of 500, since every page reads the whole fleet again.
`extra` is the row's metadata, key by key and typed as bd keeps it (the interface's conformance script holds extra to exactly what a client put there).
bd's other columns (priority, notes, design, estimate, due and the like) are not carried: no ticket field names them and extra may not.
Without a configured fleet, list leaves closed rows out, as bd list does. rev is the read helper's rev (bd's revision with the labels, the edges and the comment count).
history is bd's event log (actor, type, old and new values) with the comments merged in, oldest first.

A write holds one lock for the whole step: it replays an answered op_id, checks the rev, calls bd and reads the ticket back. bd has no
compare-and-set, so the lock closes the window against other writers of this adapter only; a bd run by hand can still write between
the check and the call. The answer of each op_id is kept in <store parent>/.jg-ticket-adapter/ops (JG_TICKET_ADAPTER_STATE moves it) for
at least 24 hours. If this process dies after bd committed and before the answer is kept, a retry repeats the write.
bd cannot remove a metadata key its own key rule refuses (^[a-zA-Z_][a-zA-Z0-9_./]*$), so unset of such a key is `invalid`.
"""
import fcntl
from concurrent.futures import ThreadPoolExecutor
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
WRAPPER = os.environ.get("JG_BEADS_SH") or os.path.join(HERE, "jg-beads.sh")
READER = os.path.join(HERE, "jg-beads-read.py")
IDENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
BD_KEY = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_./]*$")
OP_KEEP_SECONDS = 7 * 24 * 3600
STEP_TIMEOUT = 20
FLEET_PAGE = 500  # every page reads the whole fleet again, so a client that names no limit gets the largest page, not 50
BOARD_COLUMNS = ("Waiting for you", "Next up", "Being built", "Done")
BOARD_HOME = None
REQUEST_KEYS = {"describe": set(), "list": {"cursor", "limit"}, "get": {"id"}, "create": {"ticket", "op_id"}, "update": {"id", "rev", "set", "unset", "op_id"},
                "history": {"id", "cursor"}, "comment": {"id", "text", "op_id"}}
REQUIRED = {"get": ["id"], "create": ["ticket", "op_id"], "update": ["id", "rev", "op_id"], "history": ["id"], "comment": ["id", "text", "op_id"]}
TICKET_KEYS = ("title", "body", "kind", "status", "assignee", "labels", "parent", "links", "extra")


class Refusal(Exception):
    def __init__(self, code, message, retryable=False, detail=None):
        super().__init__(message)
        self.body = {"code": code, "message": message, "retryable": retryable}
        if detail is not None:
            self.body["detail"] = detail


def invalid(fields, message="The request was refused."):
    return Refusal("invalid", message, False, {"fields": [{"field": f, "message": m} for f, m in fields]})


def bd(args, stdin=None, step="bd", env=None):
    """One call of the wrapper; its stderr is the reason when it fails."""
    try:
        done = subprocess.run([WRAPPER] + args, input=stdin, capture_output=True, text=True, timeout=STEP_TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
        raise Refusal("timeout", "%s did not answer in %d seconds." % (step, STEP_TIMEOUT), True)
    except OSError as e:
        raise Refusal("unavailable", "Cannot run %s: %s" % (WRAPPER, e), True)
    return done


def read_helper(args, env=None):
    try:
        done = subprocess.run([sys.executable, READER] + args, capture_output=True, text=True, timeout=STEP_TIMEOUT * 3, env=env)
    except subprocess.TimeoutExpired:
        raise Refusal("timeout", "The ticket store did not answer in time.", True)
    return done


def reason(done):
    return (done.stderr.strip() or done.stdout.strip() or "no output")[:400]


def read_rows(ids):
    """Rows (with rev) for ids; a missing ticket is not_found, an unreadable store is unavailable."""
    done = read_helper(["show"] + ids)
    if done.returncode == 4:
        raise Refusal("not_found", "No ticket %s." % " or ".join(ids))
    if done.returncode != 0:
        raise Refusal("unavailable", "The ticket store could not be read: %s" % reason(done), True)
    return json.loads(done.stdout)


def get_row(ticket_id):
    if not isinstance(ticket_id, str) or not IDENT.match(ticket_id):
        raise Refusal("not_found", "No ticket %s." % json.dumps(ticket_id))
    return read_rows([ticket_id])[0]


def to_ticket(row):
    ticket = {"id": row["id"], "rev": row["rev"], "title": row.get("title", ""), "body": row.get("description", ""), "kind": row.get("issue_type", ""),
            "status": row.get("status", ""), "assignee": row.get("assignee") or None, "labels": list(row.get("labels") or []), "parent": row.get("parent") or None,
            "links": links_of(row), "created_at": row["created_at"], "updated_at": row["updated_at"], "extra": dict(row.get("metadata") or {})}
    if BOARD_HOME:
        name, home = BOARD_HOME
        ticket["id"] = scoped(name, ticket["id"])
        ticket["parent"] = scoped(name, ticket["parent"]) if ticket["parent"] else None
        ticket["links"] = [dict(link, id=scoped(name, link["id"])) for link in ticket["links"]]
        ticket["project"] = next((label[8:] for label in ticket["labels"] if label.startswith("project:")), None)
        ticket["status"] = column(row, home)
    return ticket


def links_of(row):
    return [{"type": e.get("dependency_type", ""), "id": e["id"]} for e in row.get("dependencies") or [] if e.get("dependency_type") != "parent-child"]


def words(command, key, extra_key):
    done = bd([command, "--json"])
    if done.returncode != 0:
        raise Refusal("unavailable", "The ticket store could not be read: %s" % reason(done), True)
    data = json.loads(done.stdout)
    return [i["name"] for k in key for i in data.get(k, [])] + [i["name"] for i in data.get(extra_key, [])]


def statuses():
    return words("statuses", ["built_in_statuses"], "custom_statuses")


def kinds():
    return words("types", ["core_types"], "custom_types")



def fleet_homes():
    """The main home and its registered local leads; fail rather than return an incomplete fleet."""
    root = os.environ.get("JG_HOME")
    if not root:
        return {}
    paths = {"main": root}
    registry = os.path.join(root, "data", "squad_leads.md")
    if os.path.isfile(registry):
        with open(registry) as handle:
            for line in handle:
                match = re.match(r"- (\S+) - .*\(home: ([^;]+);", line)
                if match:
                    if not IDENT.fullmatch(match[1]) or "--" in match[1] or match[1] in paths:
                        raise Refusal("unavailable", "Invalid or duplicate home name %s." % match[1])
                    paths[match[1]] = match[2]
                elif re.match(r"- \S+ - .*\(host:", line):
                    raise Refusal("unavailable", "A remote home requires a backlog reader.")
    homes = {}
    for name, path in paths.items():
        try:
            with open(os.path.join(path, "config", "beads-dir")) as handle: store = handle.read().strip()
        except FileNotFoundError:
            continue  # a home that names no store has no tickets (the tickets sync skips it the same way); a store it names but cannot be read still refuses below
        except OSError as e:
            raise Refusal("unavailable", "Cannot read %s's store: %s" % (name, e), True)
        if not store: continue
        if not os.path.isabs(store): raise Refusal("unavailable", "No absolute store for %s." % name)
        homes[name] = (path, store)
    return homes


def scoped(name, ident):
    return name + "--" + ident


def unscoped(ident, homes):
    if not isinstance(ident, str) or "--" not in ident:
        raise Refusal("not_found", "A fleet ticket needs its home-qualified id.")
    name, ident = ident.split("--", 1)
    if name not in homes or not IDENT.fullmatch(ident): raise Refusal("not_found", "No ticket with that id.")
    return name, ident


def column(row, home):
    meta = row.get("metadata") or {}
    status = row.get("status")
    if status == "closed":
        stamp = row.get("closed_at") or ""
        cutoff = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=7)).isoformat()
        return "Done" if stamp and stamp >= cutoff else None
    deps = row.get("dependencies") or []
    asked = any(d.get("issue_type") == "gate" and d.get("status") != "closed" and d.get("dependency_type") == "blocks" for d in deps)
    if asked:
        return "Waiting for you"
    item = str(meta.get("task") or meta.get("legacy_item") or row["id"])
    if not IDENT.fullmatch(item): return None
    state = os.path.join(home, "state")
    def read(name):
        try:
            with open(os.path.join(state, item + name)) as f: return f.read()
        except FileNotFoundError: return ""
    props = dict(line.split("=", 1) for line in read(".meta").splitlines() if "=" in line)
    lines = read(".status").splitlines()
    last = lines[-1] if lines else ""
    if (props.get("window") or props.get("endpoint")) and not os.path.exists(os.path.join(state, item + ".exit")) and not re.match(r"^(done|failed|cancelled|superseded)\b", last):
        return "Being built"
    if status == "open" and not any(d.get("dependency_type") == "blocks" and d.get("status") != "closed" for d in deps):
        return "Next up"
    return None


def fleet_rows(name, home, store, all_closed=False):
    """One home's board rows in one query; maintenance may also need older closed card sources."""
    cutoff = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
    result = read_helper(["board", '--all' if all_closed else cutoff], env=dict(os.environ, BEADS_DIR=store))
    if result.returncode: raise Refusal("unavailable", "Cannot read %s: %s" % (name, reason(result)), True)
    return [(name, home, row) for row in json.loads(result.stdout)]


def fleet_snapshot(all_closed=False):
    """One complete board read, also used by ticket maintenance without rereading the fleet for each page."""
    homes = fleet_homes()
    if not homes: return []
    with ThreadPoolExecutor(max_workers=min(8, len(homes))) as pool:
        futures = [pool.submit(fleet_rows, name, home, store, all_closed) for name, (home, store) in homes.items()]
        return [row for future in futures for row in future.result()]


def fleet_list(request):
    cursor, limit = request.get("cursor"), request.get("limit", FLEET_PAGE)
    if cursor is not None and not IDENT.fullmatch(cursor): raise invalid([("cursor", "not a fleet cursor")])
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 500: raise invalid([("limit", "must be a whole number from 1 to 500")])
    rows = fleet_snapshot()
    global BOARD_HOME
    tickets = []
    for name, home, row in rows:
        if not column(row, home): continue
        BOARD_HOME = (name, home)
        ticket = to_ticket(row)
        if not cursor or ticket["id"] > cursor: tickets.append(ticket)
    tickets.sort(key=lambda ticket: ticket["id"])
    page = tickets[:limit]
    answer = {"tickets": page, "complete": True}
    if len(tickets) > limit: answer["next_cursor"] = page[-1]["id"]
    return answer


def op_describe(request):
    def enum(name, label, values):
        return {"name": name, "type": "enum", "label": label, "values": [{"value": v} for v in values]}
    result = {"interface": 1, "backend": "beads", "capabilities": ["history", "comment"], "fields": [
        {"name": "title", "type": "string", "label": "Title", "required": True}, {"name": "body", "type": "text", "label": "Description"},
        enum("kind", "Type", kinds()), enum("status", "Status", BOARD_COLUMNS if fleet_homes() else statuses()), {"name": "assignee", "type": "string", "label": "Assignee"},
        {"name": "labels", "type": "set", "label": "Labels"}, {"name": "parent", "type": "ref", "label": "Parent"}, {"name": "links", "type": "links"},
        {"name": "created_at", "type": "datetime", "readonly": True}, {"name": "updated_at", "type": "datetime", "readonly": True}]}
    if fleet_homes():
        status = next(field for field in result["fields"] if field["name"] == "status")
        status.update(values=[{"value": word, "label": word} for word in BOARD_COLUMNS], readonly=True)
        result["fields"].append({"name": "project", "type": "string", "label": "Project", "readonly": True})
    return result


def op_list(request):
    if fleet_homes():
        return fleet_list(request)
    cursor, limit = request.get("cursor"), request.get("limit")
    problems = []
    if cursor is not None and not (isinstance(cursor, str) and IDENT.match(cursor)):
        problems.append(("cursor", "not a cursor this adapter gave"))
    if limit is not None and not (isinstance(limit, int) and not isinstance(limit, bool) and 1 <= limit <= 500):
        problems.append(("limit", "must be a whole number from 1 to 500"))
    if problems:
        raise invalid(problems)
    done = read_helper(["list", "--limit", str(limit or 50)] + (["--after", cursor] if cursor else []))
    if done.returncode == 5:
        raise Refusal("incomplete", "Only part of the ticket store could be read: %s" % reason(done), True)
    if done.returncode != 0:
        raise Refusal("unavailable", "The ticket store could not be read: %s" % reason(done), True)
    page = json.loads(done.stdout)
    answer = {"tickets": [to_ticket(r) for r in page["rows"]], "complete": True}
    if page["next"]:
        answer["next_cursor"] = page["next"]
    return answer


def op_get(request):
    return {"ticket": to_ticket(get_row(request["id"]))}


# --- writes -----------------------------------------------------------------------------------------------------------------------------

def check_fields(patch, creating):
    """Every problem with the fields of a ticket (create) or of a set (update), as (field, message) pairs."""
    problems = []
    names = {"title", "body", "kind", "status", "assignee", "labels", "parent", "links", "extra"}
    for key in patch:
        if key not in names:
            problems.append((key, "not a field a client may set" if key in ("id", "rev", "created_at", "updated_at") else "not a field of a ticket"))
    problems += [(k, "must be a string") for k in ("title", "body", "kind", "status") if k in patch and not isinstance(patch[k], str)]
    for k in ("assignee", "parent"):
        if k in patch and patch[k] is not None and not isinstance(patch[k], str):
            problems.append((k, "must be a string or null"))
    if "title" in patch and isinstance(patch["title"], str) and not patch["title"].strip():
        problems.append(("title", "cannot be empty"))
    if creating and "title" not in patch:
        problems.append(("title", "is required"))
    if "labels" in patch:
        labels = patch["labels"]
        if not isinstance(labels, list) or not all(isinstance(x, str) and x.strip() and "," not in x for x in labels):
            problems.append(("labels", "must be a list of non-empty strings without commas"))
    if "links" in patch:
        links = patch["links"]
        if not isinstance(links, list) or not all(isinstance(x, dict) and isinstance(x.get("type"), str) and x["type"] and isinstance(x.get("id"), str) and IDENT.match(x["id"]) for x in links):
            problems.append(("links", "must be a list of {type, id}"))
    if "extra" in patch:
        extra = patch["extra"]
        if not isinstance(extra, dict):
            problems.append(("extra", "must be an object"))
    return problems


def check_words(patch, problems):
    for field, allowed in (("kind", kinds), ("status", statuses)):
        if isinstance(patch.get(field), str):
            values = allowed()
            if patch[field] not in values:
                problems.append((field, "%s is not one of %s" % (patch[field], ", ".join(values))))
    if isinstance(patch.get("parent"), str):
        try:
            get_row(patch["parent"])
        except Refusal as e:
            problems.append(("parent", "no ticket %s" % patch["parent"] if e.body["code"] == "not_found" else e.body["message"]))
    for link in patch.get("links") if isinstance(patch.get("links"), list) else []:
        try:
            get_row(link["id"]) if isinstance(link, dict) and isinstance(link.get("id"), str) else None
        except Refusal as e:
            problems.append(("links", "no ticket %s" % link["id"] if e.body["code"] == "not_found" else e.body["message"]))


def bd_flags(patch):
    """The bd flags that write `patch` (title, body, kind, status, assignee, parent, extra); labels and links are separate steps."""
    flags = []
    for field, flag in (("title", "--title"), ("body", "-d"), ("kind", "-t"), ("status", "-s"), ("assignee", "-a"), ("parent", "--parent")):
        if field in patch:
            flags += [flag, patch[field] or ""]
    if patch.get("extra"):
        flags += ["--metadata", json.dumps(patch["extra"])]
    return flags


def refuse_write(done, what):
    if done.returncode == 13:
        raise Refusal("conflict", "%s changed while it was being written." % what, True)
    raise Refusal("denied", "bd refused the write: %s" % reason(done))


def set_links(ticket_id, have, want):
    key = lambda l: (l["type"], l["id"])
    have_keys, want_keys = {key(l) for l in have}, {key(l) for l in want}
    steps = [["dep", "remove", ticket_id, i] for t, i in sorted(have_keys - want_keys)]
    steps += [["dep", "add", ticket_id, i, "--type", t] for t, i in sorted(want_keys - have_keys)]
    for step in steps:
        done = bd(step)
        if done.returncode != 0:
            raise Refusal("internal", "Step %s of the write failed after the earlier ones landed; read %s again: %s" % (" ".join(step[:3]), ticket_id, reason(done)))


def op_create(request):
    ticket = request["ticket"]
    if not isinstance(ticket, dict):
        raise invalid([("ticket", "must be an object")])
    problems = check_fields(ticket, True)
    if not problems:
        check_words(ticket, problems)
    if problems:
        raise invalid(problems)
    args = ["create", "--silent"] + bd_flags({k: v for k, v in ticket.items() if k in ("title", "body", "kind", "status", "assignee", "parent", "extra")})
    if ticket.get("labels"):
        args += ["-l", ",".join(ticket["labels"])]
    done = bd(args)
    if done.returncode != 0:
        refuse_write(done, "The new ticket")
    ticket_id = done.stdout.strip().splitlines()[-1] if done.stdout.strip() else ""
    if not IDENT.match(ticket_id):
        raise Refusal("internal", "bd created a ticket but printed no id: %s" % reason(done))
    set_links(ticket_id, [], ticket.get("links") or [])
    return {"ticket": to_ticket(get_row(ticket_id))}


def op_update(request):
    row = get_row(request["id"])
    patch, unset = request.get("set"), request.get("unset")
    problems = []
    if patch is not None and not isinstance(patch, dict):
        problems.append(("set", "must be an object"))
    if unset is not None and not (isinstance(unset, list) and all(isinstance(k, str) and k for k in unset)):
        problems.append(("unset", "must be a list of extra keys"))
    if not problems:
        patch, unset = patch or {}, unset or []
        if not patch and not unset:
            problems.append(("set", "names nothing to change"))
        problems += check_fields(patch, False)
        clash = sorted(set(unset) & set(patch.get("extra") if isinstance(patch.get("extra"), dict) else {}))
        problems += [("unset", "%s is also in set.extra" % k) for k in clash]
        problems += [("unset", "bd cannot remove %s: its key rule refuses that name" % k) for k in unset if not BD_KEY.match(k)]
        if not problems:
            check_words(patch, problems)
    if problems:
        raise invalid(problems)
    if row["rev"] != request["rev"]:
        raise Refusal("conflict", "%s changed since it was read (rev %s, now %s)." % (row["id"], request["rev"], row["rev"]), False, {"current": to_ticket(row)})
    flags = bd_flags(patch)
    if "labels" in patch:
        have = set(row.get("labels") or [])
        flags += [x for l in sorted(have - set(patch["labels"])) for x in ("--remove-label", l)] + [x for l in patch["labels"] if l not in have for x in ("--add-label", l)]
    for key in unset:
        flags += ["--unset-metadata", key]
    if flags:
        done = bd(["update", row["id"]] + flags)
        if done.returncode != 0:
            refuse_write(done, row["id"])
    if "links" in patch:
        set_links(row["id"], links_of(row), patch["links"])
    return {"ticket": to_ticket(get_row(row["id"]))}


def comments_of(ticket_id):
    done = bd(["comments", ticket_id, "--json"])
    if done.returncode != 0:
        raise Refusal("unavailable", "The comments could not be read: %s" % reason(done), True)
    return json.loads(done.stdout or "[]")


def comment_event(c):
    return {"id": c["id"], "at": c["created_at"], "actor": c.get("author") or None, "type": "comment", "text": c["text"], "changes": [], "extra": {}}


def op_comment(request):
    text = request["text"]
    if not isinstance(text, str) or not text.strip():
        raise invalid([("text", "must be a non-empty string")])
    row = get_row(request["id"])
    done = bd(["comment", row["id"], "--stdin", "--json"], stdin=text)
    if done.returncode != 0:
        refuse_write(done, row["id"])
    try:
        return {"event": comment_event(json.loads(done.stdout))}
    except (ValueError, KeyError):
        raise Refusal("internal", "bd added the comment but did not answer it: %s" % reason(done))


def changes_of(event):
    """{field, from, to} for each field the bd event's new_value names; bd's own column names are the record's where they differ."""
    try:
        old, new = json.loads(event.get("old_value") or "{}"), json.loads(event.get("new_value") or "{}")
    except ValueError:
        return []
    if not isinstance(old, dict) or not isinstance(new, dict):
        return []
    out = []
    for key, value in new.items():
        if key == "metadata" and isinstance(value, dict):
            before = old.get("metadata") or {}
            out += [{"field": "extra.%s" % k, "from": before.get(k), "to": value.get(k)} for k in sorted(set(before) | set(value)) if before.get(k) != value.get(k)]
        else:
            field = {"description": "body", "issue_type": "kind"}.get(key, key if key in ("title", "status", "assignee", "parent") else "extra.%s" % key)
            blank = lambda v: None if field in ("assignee", "parent") and v == "" else v
            out.append({"field": field, "from": blank(old.get(key)), "to": blank(value)})
    return out


def op_history(request):
    row = get_row(request["id"])
    done = bd(["history", row["id"], "--events", "--json"])
    if done.returncode != 0:
        raise Refusal("unavailable", "The history could not be read: %s" % reason(done), True)
    # bd lists newest first and stamps whole seconds; reversing keeps its order inside one second.
    events = [{"id": e["id"], "at": e["created_at"], "actor": e.get("actor") or None, "type": e["event_type"], "text": e.get("comment"), "changes": changes_of(e), "extra": {}}
              for e in reversed(json.loads(done.stdout or "[]"))]
    events += [comment_event(c) for c in comments_of(row["id"])]
    events.sort(key=lambda e: (e["at"], e["type"] != "created"))  # whole seconds: the creation comes first inside its own second.
    return {"events": events}


OPERATIONS = {"describe": op_describe, "list": op_list, "get": op_get, "create": op_create, "update": op_update, "history": op_history, "comment": op_comment}
WRITES = {"create", "update", "comment"}


# --- the op_id record and the entry point -----------------------------------------------------------------------------------------------

def state_dir():
    configured = os.environ.get("JG_TICKET_ADAPTER_STATE")
    if configured:
        return configured
    beads = os.environ.get("BEADS_DIR")
    if not beads or not os.path.isabs(beads):
        raise Refusal("unavailable", "BEADS_DIR is not set to the store's .beads folder.", False)
    return os.path.join(os.path.dirname(beads.rstrip("/")), ".jg-ticket-adapter")


class OpLog:
    def __init__(self, op, request):
        self.root = os.path.join(state_dir(), "ops")
        os.makedirs(self.root, exist_ok=True)
        self.lock = open(os.path.join(self.root, "lock"), "a")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        self.fingerprint = hashlib.sha256(json.dumps([op, {k: v for k, v in request.items() if k != "op_id"}], sort_keys=True).encode()).hexdigest()
        self.path = os.path.join(self.root, hashlib.sha256(request["op_id"].encode()).hexdigest()[:40] + ".json")

    def replay(self):
        try:
            with open(self.path) as f:
                kept = json.load(f)
        except (OSError, ValueError):
            return None
        if kept.get("fingerprint") != self.fingerprint:
            raise invalid([("op_id", "was already used for another request")])
        return kept["response"]

    def keep(self, response):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"fingerprint": self.fingerprint, "response": response, "at": time.time()}, f)
        os.replace(tmp, self.path)
        for name in os.listdir(self.root):
            full = os.path.join(self.root, name)
            if name.endswith(".json") and time.time() - os.path.getmtime(full) > OP_KEEP_SECONDS:
                os.remove(full)


def parse(op, raw):
    if op not in OPERATIONS:
        raise Refusal("unsupported", "This adapter has no operation %s." % op)
    try:
        request = json.loads(raw)
    except ValueError:
        request = None
    if not isinstance(request, dict):
        raise invalid([("request", "must be one JSON object")], "The request is not one JSON object.")
    if request.get("interface") != 1:
        raise Refusal("unsupported", "This adapter speaks interface 1, not %s." % json.dumps(request.get("interface")))
    unknown = sorted(set(request) - REQUEST_KEYS[op] - {"interface"})
    if unknown:
        raise Refusal("unsupported", "%s takes no key %s." % (op, ", ".join(unknown)))
    missing = [k for k in REQUIRED.get(op, []) if k not in request]
    if missing:
        raise invalid([(k, "is required") for k in missing])
    for key in ("id", "rev", "op_id", "cursor"):
        if key in request and not (isinstance(request[key], str) and request[key]):
            raise invalid([(key, "must be a non-empty string")])
    if "op_id" in request and len(request["op_id"]) > 128:
        raise invalid([("op_id", "is longer than 128 characters")])
    request.pop("interface")
    return request


def run(op, raw):
    global BOARD_HOME
    request = parse(op, raw)
    homes = fleet_homes()
    if homes and op == "describe":
        os.environ["BEADS_DIR"] = homes["main"][1]
    if homes and op not in ("describe", "list"):
        if op == "create":
            name = "main"
        else:
            name, request["id"] = unscoped(request["id"], homes)
        BOARD_HOME = (name, homes[name][0])
        os.environ["BEADS_DIR"] = homes[name][1]
        patch = request.get("ticket") if op == "create" else request.get("set")
        if isinstance(patch, dict):
            if "status" in patch or "project" in patch:
                raise invalid([(k, "is read-only on the fleet board") for k in ("status", "project") if k in patch])
            if patch.get("parent"):
                owner, patch["parent"] = unscoped(patch["parent"], homes)
                if owner != name: raise invalid([("parent", "must belong to the same home")])
            for link in patch.get("links") or []:
                owner, link["id"] = unscoped(link["id"], homes)
                if owner != name: raise invalid([("links", "must belong to the same home")])
    if op not in WRITES:
        return OPERATIONS[op](request)
    log = OpLog(op, request)
    try:
        kept = log.replay()
        if kept is not None:
            return kept
        response = OPERATIONS[op](request)
        log.keep(response)
        return response
    finally:
        log.lock.close()


def main(argv):
    op = argv[0] if len(argv) == 1 else ""
    try:
        if not op:
            raise Refusal("unsupported", "usage: jg-ticket-adapter.py <%s>" % "|".join(OPERATIONS))
        response, code = run(op, sys.stdin.read()), 0
    except Refusal as e:
        response, code = {"error": e.body}, 1
    except Exception as e:  # the contract is one JSON answer, so an adapter bug is `internal`, never a traceback.
        response, code = {"error": {"code": "internal", "message": "The adapter failed: %s: %s" % (type(e).__name__, e), "retryable": False}}, 1
    sys.stdout.write(json.dumps(response) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
