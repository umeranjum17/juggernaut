"""bd_forms/update.py: `bd update <id>... [flags]` answered from the tickets tables of fleet.db (mode tables of bd_compat.py).
run(argv, stdin_text) -> (stdout_text, exit_status). Each flag has one handler in FLAGS that edits one ticket row; a call
that names a flag outside FLAGS raises NotSupported. Writes go through tickets.change, one log row per ticket.
Exit 0 done; 1 a failure (unknown id, bad value); 2 the hold-reason rule jg-beads.sh adds to bd; 13 a stale --if-status or
--if-assignee guard (nothing written). The same guards, in the same order, as bd 1.3. Python stdlib only."""
import json, os, re, sys, time

ADAPTERS = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, ADAPTERS)
import itemdb  # noqa: E402  (bd_compat.py put the store folder on sys.path)
import tickets  # noqa: E402

TYPES = {"bug", "feature", "task", "epic", "chore", "decision", "spike", "story", "milestone", "gate"}
TYPE_ALIASES = {"enhancement": "feature", "feat": "feature", "dec": "decision", "adr": "decision"}


class NotSupported(Exception):
    """The call uses a flag or a shape this module does not answer."""


class Failed(Exception):
    def __init__(self, message, status=1):
        super().__init__(message)
        self.status = status


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# --- one handler per flag: (ticket, value, call) edits the ticket dict in place. A ticket is the row tickets.copy_of gives.

def set_field(name):
    def handler(t, value, call):
        t[name] = value if value != "" else None
    return handler


def h_status(t, value, call):
    if value == "closed" and t["status"] != "closed":
        t["closed_at"] = call.now
    elif value != "closed":
        t["closed_at"], t["close_reason"] = None, None
    t["status"] = value


def h_defer(t, value, call):
    if value == "":
        t["defer_until"] = None
        return
    t["defer_until"] = value if re.search(r"T\d\d:\d\d", value) else value + "T00:00:00Z"
    if "-s" not in call.flags and "--status" not in call.flags:
        t["status"] = "deferred"


def h_priority(t, value, call):
    m = re.fullmatch(r"[Pp]?([0-4])", value)
    if not m:
        raise Failed("invalid priority %r (want 0-4 or P0-P4)" % value)
    t["priority"] = int(m.group(1))


def h_type(t, value, call):
    kind = TYPE_ALIASES.get(value, value)
    if kind not in TYPES:
        raise Failed("invalid issue type %r" % value)
    t["issue_type"] = kind


def h_add_label(t, value, call):
    t["labels"] = sorted(set(t["labels"]) | set(v for v in value.split(",") if v))


def h_remove_label(t, value, call):
    drop = set(value.split(","))
    t["labels"] = [x for x in t["labels"] if x not in drop]


def h_set_labels(t, value, call):
    t["labels"] = sorted(set(v for v in value.split(",") if v))


def h_metadata(t, value, call):
    try:
        meta = json.loads(open(value[1:], encoding="utf-8").read() if value.startswith("@") else value)
    except (OSError, ValueError) as e:
        raise Failed("--metadata: %s" % (str(e).splitlines() or ["invalid JSON"])[0])
    if not isinstance(meta, dict):
        raise Failed("--metadata must be a JSON object")
    t["metadata"] = meta


def h_set_metadata(t, value, call):
    key, eq, val = value.partition("=")
    if not eq or not key:
        raise Failed("--set-metadata wants key=value, got %r" % value)
    t["metadata"][key] = val


def h_unset_metadata(t, value, call):
    t["metadata"].pop(value, None)


def h_body(t, value, call):
    text = call.stdin if value == "-" else read_file(value)
    if text == "" and "--allow-empty-description" not in call.flags:
        raise Failed("refusing to replace the description with empty text (pass --allow-empty-description)")
    t["description"] = text if text != "" else None


def read_file(path):
    try:
        return open(path, encoding="utf-8", newline="").read()
    except OSError as e:
        raise Failed("cannot read %s: %s" % (path, e.strerror))


def h_stdin(t, value, call):
    h_body(t, "-", call)


def h_parent(t, value, call):
    t["links"] = [lk for lk in t["links"] if lk[2] != "parent-child"]
    if value:
        t["links"].append((t["id"], value, "parent-child"))


def h_nothing(t, value, call):
    """A flag that only guards or permits another: --force, --allow-empty-description."""


# flag -> (takes a value, handler). A short form maps to its long one in SHORT.
FLAGS = {
    "--title": (True, set_field("title")),
    "--description": (True, set_field("description")),
    "--body-file": (True, h_body),
    "--stdin": (False, h_stdin),
    "--allow-empty-description": (False, h_nothing),
    "--assignee": (True, set_field("assignee")),
    "--status": (True, h_status),
    "--priority": (True, h_priority),
    "--type": (True, h_type),
    "--defer": (True, h_defer),
    "--external-ref": (True, set_field("external_ref")),
    "--add-label": (True, h_add_label),
    "--remove-label": (True, h_remove_label),
    "--set-labels": (True, h_set_labels),
    "--metadata": (True, h_metadata),
    "--set-metadata": (True, h_set_metadata),
    "--unset-metadata": (True, h_unset_metadata),
    "--parent": (True, h_parent),
    "--force": (False, h_nothing),
    "--if-status": (True, None),       # guards: read by check_guards, never applied
    "--if-assignee": (True, None),
}
SHORT = {"-a": "--assignee", "-d": "--description", "-p": "--priority", "-s": "--status", "-t": "--type"}


class Call:
    def __init__(self, argv, stdin_text):
        self.stdin, self.ids, self.steps, self.flags, self.guards = stdin_text, [], [], set(), {}
        i = 0
        while i < len(argv):
            word = argv[i]
            i += 1
            if not word.startswith("-") or word == "-":
                self.ids.append(word)
                continue
            name, eq, value = word.partition("=")
            name = SHORT.get(name, name)
            if name not in FLAGS:
                raise NotSupported(word)
            takes, handler = FLAGS[name]
            if takes and not eq:
                if i >= len(argv):
                    raise Failed("flag needs an argument: %s" % word)
                value, i = argv[i], i + 1
            self.flags.add(word.split("=", 1)[0])
            self.flags.add(name)
            if handler is None:
                self.guards[name] = value
            else:
                self.steps.append((handler, value))
        if not self.ids:
            raise Failed("no issue ID given")
        self.now = now_iso()


def check_reason_rule(call, store, home_id):
    """The hold-reason rule of bin/jg-beads.sh: a call that defers a row names a reason, and one that strips a reason
    moves the row out of deferred."""
    deferring = reason = strips = moves = False
    for handler, value in call.steps:
        if handler is h_status:
            deferring, moves = deferring or value == "deferred", moves or value != "deferred"
        elif handler is h_defer:
            deferring = deferring or value != ""
        elif handler is h_set_metadata and value.startswith("hold_reason="):
            reason, strips = reason or bool(value[12:].strip()), strips or not value[12:].strip()
        elif handler is h_unset_metadata and value == "hold_reason":
            strips = True
        elif handler is h_metadata:
            try:
                kept = str((json.loads(value) or {}).get("hold_reason") or "").strip() if not value.startswith("@") else ""
            except ValueError:
                kept = ""
            reason, strips = reason or bool(kept), strips or not kept
    if deferring and not reason:
        raise Failed("a deferred row needs a reason: pass --set-metadata hold_reason=<text> in the same call", 2)
    if strips and not moves:
        for ident in call.ids:
            row = tickets.copy_of(store.con, home_id, ident)
            if row is not None and row["status"] == "deferred":
                raise Failed("%s is deferred and needs its reason: unhold it first" % ident, 2)


def guards_hold(call, t):
    if "--if-status" in call.guards and (t["status"] or "") != call.guards["--if-status"]:
        return False
    return "--if-assignee" not in call.guards or (t["assignee"] or "") == call.guards["--if-assignee"]


def check_close(t, store, home_id, call):
    """bd refuses to close a row with an open child or an open blocker, unless --force."""
    if t["status"] != "closed" or "--force" in call.flags:
        return
    con = store.con
    open_below = con.execute("SELECT l.from_id FROM link l JOIN ticket c ON c.home = l.home AND c.id = l.from_id "
                             "WHERE l.home = ? AND l.to_id = ? AND l.type = 'parent-child' AND c.status != 'closed'",
                             (home_id, t["id"])).fetchall()
    blockers = [b for _, b, ty in t["links"] if ty == "blocks"
                and (con.execute("SELECT status FROM ticket WHERE home = ? AND id = ?", (home_id, b)).fetchone() or ("closed",))[0] != "closed"]
    if open_below or blockers:
        raise Failed("cannot close %s: %s (use --force to override)"
                     % (t["id"], "open children " + ", ".join(i for (i,) in open_below) if open_below else "open blockers " + ", ".join(blockers)))


def export_row(t):
    body = {k: t[k] for k in tickets.FIELDS}
    body.update(labels=t["labels"], metadata=t["metadata"], ephemeral=t["ephemeral"], id=t["id"],
                dependencies=t["edges"])
    return body


def run(argv, stdin_text):
    try:
        return answer(Call(argv[1:], stdin_text))
    except Failed as e:
        sys.stderr.write("%s\n" % e)
        return "", e.status


def answer(call):
    try:
        h = tickets.home()
        home_id = itemdb.home_id(h)
        store = tickets.open_tickets(h)
        check_reason_rule(call, store, home_id)
        out, stale, failed, at = [], 0, [], int(time.time())
        source = "bd-update:%d" % time.time_ns()
        for ident in call.ids:
            t = tickets.copy_of(store.con, home_id, ident)
            if t is None:
                failed.append("no issue found matching %r" % ident)
                continue
            if not guards_hold(call, t):
                stale += 1
                sys.stderr.write("%s: the --if-status or --if-assignee guard no longer holds; nothing written\n" % ident)
                continue
            try:
                for handler, value in call.steps:
                    handler(t, value, call)
                check_close(t, store, home_id, call)
            except Failed as e:
                failed.append("%s: %s" % (ident, e))
                continue
            tickets.change(store, at, home_id, "update", "%s#%s" % (source, ident), export_row(t))
            out.append("✓ Updated issue: %s — %s\n" % (ident, t["title"]))
    except (tickets.Refused, itemdb.Unbound) as e:
        raise Failed(str(e))
    for line in failed:
        sys.stderr.write(line + "\n")
    return "".join(out), (1 if failed else 13 if stale else 0)
