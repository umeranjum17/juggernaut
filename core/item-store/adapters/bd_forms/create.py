"""bd_forms/create.py: the `create` family of bd calls, answered from the ticket tables (fleet.db) in mode `tables`.

  run(argv, stdin_text) -> (stdout_text, exit_status)

Answers `create`: one new row, written through tickets.change (the writer every family uses), so
ticket_change keeps the history. It prints what bd printed: the text block, the --json object or the --silent id line.
Also answered, each written through tickets.change or its own table: `comment` and `comments add` (the comment table), `import`
(rows by tickets.change, `_type: memory` lines into the memory table), `remember --key` (the memory table) and `gate create --blocks`
(a gate row, plus the blocked ticket's new link; a gate's await_type is always human, the one type the form records).
A form it cannot answer with bd's exact bytes raises NotSupported: a call it has no recorded answer for (a flag it does not know, a missing
parent, dependency, ticket or file, a failed --validate, a gate of another type). The hold-reason rule (a deferred row needs a hold reason) is kept:
it refuses with exit 2. Python stdlib only."""
import json, os, re, secrets, sys, time, uuid

ADAPTERS = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, ADAPTERS)
import tickets  # noqa: E402
import itemdb  # noqa: E402  (tickets.py put the store folder on the path)

VALUE = {"--title": "title", "-t": "type", "--type": "type", "-p": "priority", "--priority": "priority",
         "-d": "description", "--description": "description", "--body-file": "body_file", "--id": "id", "--parent": "parent",
         "--metadata": "metadata", "-s": "status", "--status": "status", "-a": "assignee", "--assignee": "assignee",
         "--defer": "defer", "--deps": "deps", "-l": "labels", "--labels": "labels", "--blocks": "blocks", "--reason": "reason"}
FLAG = {"--force": "force", "--json": "json", "--silent": "silent", "--validate": "validate", "--no-inherit-labels": "no_inherit"}
REQUIRED = {"bug": ("## Steps to Reproduce", "## Acceptance Criteria"), "epic": ("## Success Criteria",),
            "task": ("## Acceptance Criteria",), "feature": ("## Acceptance Criteria",), "chore": ("## Acceptance Criteria",)}
LINKS = ("blocks", "related", "parent-child")
HOLD_REASON = re.compile(r'"hold_reason"\s*:\s*"\s*[^"\s]')


class NotSupported(Exception):
    """A form this module does not answer."""


def parse(args):
    """The call's options: --flag value, --flag=value and a lone positional word (the title of a create)."""
    got, words, i = {"labels": [], "deps": []}, [], 0
    while i < len(args):
        a = args[i]
        name, eq, val = a.partition("=") if a.startswith("--") else (a, "", "")
        if name in FLAG and not eq:
            got[FLAG[name]] = True
        elif name in VALUE:
            if not eq:
                if i + 1 >= len(args):
                    raise NotSupported(a)
                i, val = i + 1, args[i + 1]
            key = VALUE[name]
            if key in ("labels", "deps"):
                got[key] += [x.strip() for x in val.split(",") if x.strip()]
            else:
                got[key] = val
        elif a.startswith("-") and a != "-":
            raise NotSupported(a)
        else:
            words.append(a)
        i += 1
    return got, words


def clock():
    """(seconds as the export keeps it, nanoseconds as bd prints it): both UTC, the fraction without trailing zeros."""
    ns = time.time_ns()
    sec = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ns // 10**9))
    frac = ("%09d" % (ns % 10**9)).rstrip("0")
    return sec, sec[:-1] + ("." + frac if frac else "") + "Z"


def reason_check(opt):
    """The hold-reason rule for a create: a call that defers a row names its hold reason."""
    deferring = opt.get("status") == "deferred" or bool(opt.get("defer"))
    if deferring and not HOLD_REASON.search("--metadata=" + opt.get("metadata", "")):
        sys.stderr.write("jg-beads: a deferred row needs a reason: pass --set-metadata hold_reason=<text> in the same call\n")
        return False
    return True


def prefix_of(con, home_id):
    """The prefix new ids take: the one most of this home's ids start with (the text before the first dash), else jg."""
    count = {}
    for (i,) in con.execute("SELECT id FROM ticket WHERE home = ?", (home_id,)):
        p = i.split("-", 1)[0] if "-" in i else ""
        count[p] = count.get(p, 0) + 1
    count.pop("", None)
    return max(sorted(count), key=count.get) if count else "jg"


def new_id(con, home_id, prefix):
    """prefix-<3 base36 characters>, a longer tail after a collision."""
    width = 3
    while True:
        for _ in range(36 ** width):
            cand = "%s-%s" % (prefix, "".join(secrets.choice("0123456789abcdefghijklmnopqrstuvwxyz") for _ in range(width)))
            if not con.execute("SELECT 1 FROM ticket WHERE home = ? AND id = ?", (home_id, cand)).fetchone():
                return cand
        width += 1


def child_id(con, home_id, parent):
    """parent.N, N one past the highest direct child."""
    top = 0
    for (i,) in con.execute("SELECT id FROM ticket WHERE home = ? AND id LIKE ?", (home_id, parent.replace("%", "").replace("_", "") + ".%")):
        tail = i[len(parent) + 1:]
        if tail.isdigit():
            top = max(top, int(tail))
    return "%s.%d" % (parent, top + 1)


def json_text(obj):
    """Go's encoding/json as bd prints it: indented, keys sorted, < > & escaped, a closing newline."""
    text = json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False)
    for ch, esc in (("<", "\\u003c"), (">", "\\u003e"), ("&", "\\u0026"), (" ", "\\u2028"), (" ", "\\u2029")):
        text = text.replace(ch, esc)
    return text + "\n"


def issue_json(row):
    out = {"created_at": row["created_nano"], "updated_at": row["created_nano"], "created_by": row["by"], "id": row["id"],
           "issue_type": row["issue_type"], "priority": row["priority"], "schema_version": 1, "status": row["status"], "title": row["title"]}
    for k in ("description", "assignee"):
        if row.get(k):
            out[k] = row[k]
    if row["labels"]:
        out["labels"] = row["labels"]
    if row["metadata"]:
        out["metadata"] = row["metadata"]
    return json_text(out)


def check_validate(opt, kind, description):
    if opt.get("validate"):
        for section in REQUIRED.get(kind, ()):
            if section not in description:
                raise NotSupported("--validate refusal")


def existing(con, home_id, ident):
    copy = tickets.copy_of(con, home_id, ident)
    if copy is None:
        raise NotSupported("no ticket %s" % ident)
    return copy


def do_create(argv, stdin_text):
    opt, words = parse(argv[1:])
    if not reason_check(opt):
        return "", 2
    title = opt.get("title") or (words[0] if len(words) == 1 else "")
    if not title or opt.get("defer") or (opt.get("title") and words) or len(words) > 1:
        raise NotSupported("title or --defer")
    try:
        priority = int(re.sub(r"^[Pp]", "", opt.get("priority", "2")))
        metadata = json.loads(opt.get("metadata") or "{}")
    except ValueError:
        raise NotSupported("priority or metadata")
    if not 0 <= priority <= 4 or not isinstance(metadata, dict):
        raise NotSupported("priority or metadata")
    description = opt.get("description", "")
    if opt.get("body_file"):
        if opt["body_file"] != "-":
            raise NotSupported("--body-file path")
        description = stdin_text
    kind, status = opt.get("type", "task"), opt.get("status", "open")
    check_validate(opt, kind, description)
    h = tickets.home()
    st = tickets.open_tickets(h)
    con, home_id = st.con, itemdb.home_id(h)
    sec, nano = clock()
    con.execute("BEGIN IMMEDIATE")
    try:
        labels, links = set(opt["labels"]), []
        parent = opt.get("parent")
        if parent:
            if opt.get("id"):
                raise NotSupported("--parent with --id")
            labels |= set() if opt.get("no_inherit") else set(existing(con, home_id, parent)["labels"])
            ident = child_id(con, home_id, parent)
            links.append((parent, "parent-child"))
        elif opt.get("id"):
            ident = opt["id"]
            if (ident.split("-", 1)[0] != prefix_of(con, home_id) and not opt.get("force")) or tickets.copy_of(con, home_id, ident):
                raise NotSupported("--id %s" % ident)
        else:
            ident = new_id(con, home_id, prefix_of(con, home_id))
        for dep in opt["deps"]:
            ty, _, to = dep.rpartition(":") if ":" in dep else ("blocks", "", dep)
            if ty not in LINKS:
                raise NotSupported("dependency type %s" % ty)
            existing(con, home_id, to)
            links.append((to, ty))
        row = dict(id=ident, title=title, description=description or None, status=status, priority=priority, issue_type=kind,
                   assignee=opt.get("assignee") or None, created_at=sec, labels=sorted(labels), metadata=metadata, ephemeral=0,
                   dependencies=[tickets.new_edge(to, ty) for to, ty in links])
        tickets.change(st, int(time.time()), home_id, "create", "bd-create:%d" % time.time_ns(), row)
        con.execute("COMMIT")
    except BaseException:
        con.execute("ROLLBACK")
        raise
    shown = dict(row, by=os.environ.get("BEADS_ACTOR") or "juggernaut", created_nano=nano, description=description)
    if opt.get("json"):
        return issue_json(shown), 0
    if opt.get("silent"):
        return ident + "\n", 0
    return "✓ Created issue: %s — %s\n  Priority: P%d\n  Status: %s\n" % (ident, title, priority, status), 0


def row_of(t):
    """A ticket as tickets.change takes it: the copy's fields, links and comments (a stream it omits stays as the copy holds it)."""
    body = {k: t[k] for k in tickets.FIELDS}
    body.update(labels=t["labels"], metadata=t["metadata"], ephemeral=t["ephemeral"], id=t["id"], comments=t["comments"],
                dependencies=[{"depends_on_id": to, "type": ty} for _, to, ty in t["links"]])
    return body


def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        raise NotSupported("file %s" % path)


def actor():
    return os.environ.get("BEADS_ACTOR") or "juggernaut"


def write_in(fn):
    """Run fn(st, con, home_id, at) inside one write transaction on this home's store; its (out, status) is the answer."""
    h = tickets.home()
    st = tickets.open_tickets(h)
    con, home_id = st.con, itemdb.home_id(h)
    con.execute("BEGIN IMMEDIATE")
    try:
        answer = fn(st, con, home_id, int(time.time()))
        con.execute("COMMIT")
    except BaseException:
        con.execute("ROLLBACK")
        raise
    return answer


def do_comment(argv, stdin_text):
    """comment <id> <text...> | --stdin [--json] and comments add <id> <text...> | -f <file>."""
    plural = argv[0] == "comments"
    args = argv[2:] if plural else argv[1:]
    json_out, use_stdin, path, words = False, False, None, []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--json" and not plural:
            json_out = True
        elif a == "--stdin" and not plural:
            use_stdin = True
        elif a in ("-f", "--file") and plural and i + 1 < len(args):
            i, path = i + 1, args[i + 1]
        elif a.startswith("-") and a != "-":
            raise NotSupported(a)
        else:
            words.append(a)
        i += 1
    if not words:
        raise NotSupported("no ticket")
    ident, text_words = words[0], words[1:]
    if sum(map(bool, (use_stdin, path, text_words))) != 1:
        raise NotSupported("comment text")
    text = stdin_text.strip() if use_stdin else read_text(path) if path else " ".join(text_words)
    if not text.strip():
        raise NotSupported("empty comment")
    sec, _ = clock()

    def add(st, con, home_id, at):
        t = existing(con, home_id, ident)
        author = actor()
        cid = str(uuid.uuid5(uuid.NAMESPACE_URL, "%s|%s|%s|%d" % (ident, author, text, time.time_ns())))
        t["comments"] = t["comments"] + [{"id": cid, "author": author, "text": text, "created_at": sec}]
        tickets.change(st, at, home_id, "comment", "bd-comment:%d" % time.time_ns(), row_of(t))
        return t["title"], dict(author=author, created_at=sec, id=cid, issue_id=ident, schema_version=1, text=text)
    title, shown = write_in(add)
    if json_out:
        return json_text(shown), 0
    return ("Comment added to %s\n" % ident) if plural else ("✓ Comment added to %s — %s\n" % (ident, title)), 0


def do_remember(argv):
    """remember <content> --key <key>."""
    args = argv[1:]
    if len(args) != 3 or args[1] != "--key" or args[0].startswith("-") or args[2].startswith("-") or not args[0].strip() or not args[2].strip():
        raise NotSupported("remember")
    content, key = args[0], args[2]

    def put(st, con, home_id, at):
        old = con.execute("SELECT 1 FROM memory WHERE home = ? AND key = ?", (home_id, key)).fetchone()
        con.execute("INSERT INTO memory (home, key, value) VALUES (?,?,?) ON CONFLICT (home, key) DO UPDATE SET value = excluded.value", (home_id, key, content))
        return "%s [%s]: %s\n" % ("Updated" if old else "Remembered", key, content), 0
    return write_in(put)


def do_import(argv, stdin_text):
    """import <file> | -: every row an upsert through tickets.change (an equal row is left alone), every memory line into memory."""
    if len(argv) != 2 or (argv[1].startswith("-") and argv[1] != "-"):
        raise NotSupported("import")
    lines = [ln for ln in (stdin_text if argv[1] == "-" else read_text(argv[1])).splitlines() if ln.strip()]
    if not lines:
        sys.stderr.write("Empty file: %s\n" % argv[1])
        return "", 0
    try:
        rows = [json.loads(ln) for ln in lines]
    except ValueError:
        raise NotSupported("import: a line that is not JSON")
    if not all(isinstance(r, dict) and (r.get("_type") == "memory" and r.get("key") or r.get("id")) for r in rows):
        raise NotSupported("import: a row with no id")

    def load(st, con, home_id, at):
        source, issues, memories = "bd-import:%d" % time.time_ns(), 0, 0
        for r in rows:
            if r.get("_type") == "memory":
                con.execute("INSERT INTO memory (home, key, value) VALUES (?,?,?) ON CONFLICT (home, key) DO UPDATE SET value = excluded.value",
                            (home_id, r["key"], r.get("value", "")))
                memories += 1
                continue
            have = tickets.copy_of(con, home_id, r["id"])
            issues += 1
            if have is None or tickets.diffs(tickets.norm(r), have):
                tickets.change(st, at, home_id, "import", "%s#%s" % (source, r["id"]), r)
        sys.stderr.write("Imported %d issues%s from %s\n" % (issues, " and %d memories" % memories if memories else "", argv[1]))
        return "", 0
    return write_in(load)


def do_gate_create(argv):
    """gate create --blocks <id> --title <text> [--reason <text>] [--type human] [--json]."""
    opt, words = parse(argv[2:])
    kind = opt.pop("type", "human")
    blocks, title = opt.pop("blocks", ""), opt.pop("title", "")
    if words or kind != "human" or not blocks or not title or set(opt) - {"reason", "json", "labels", "deps"} or opt["labels"] or opt["deps"]:
        raise NotSupported("gate create")
    reason = opt.get("reason", "")
    sec, nano = clock()
    description = "Ad-hoc gate blocking %s" % blocks + ("\n\nReason: %s" % reason if reason else "")

    def make(st, con, home_id, at):
        blocked = existing(con, home_id, blocks)
        ident = new_id(con, home_id, prefix_of(con, home_id))
        row = dict(id=ident, title=title, description=description, status="open", priority=2, issue_type="gate", assignee=None,
                   created_at=sec, created_by=actor(), updated_at=sec, labels=[], metadata={}, ephemeral=0, dependencies=[])
        tickets.change(st, at, home_id, "gate-create", "bd-gate-create:%d" % time.time_ns(), row)
        blocked["links"] = blocked["links"] + [(blocks, ident, "blocks")]
        tickets.change(st, at, home_id, "gate-block", "bd-gate-block:%d#%s" % (time.time_ns(), blocks), row_of(blocked))
        return ident, blocked["title"]
    ident, blocked_title = write_in(make)
    if opt.get("json"):
        return json_text(dict(await_type="human", created_at=nano, created_by=actor(), description=description, id=ident, issue_type="gate",
                              priority=2, schema_version=1, status="open", title=title, updated_at=nano)), 0
    return ("✓ Created gate %s (type: human)\n  Blocks: %s (%s)\n%s\nResolve with: bd gate resolve %s\n"
            % (ident, blocks, blocked_title, "  Reason: %s\n" % reason if reason else "", ident)), 0


def run(argv, stdin_text):
    head = argv[:1]
    if head == ["create"]:
        return do_create(argv, stdin_text)
    if head in (["comment"], ["comments"]) and (head == ["comment"] or argv[1:2] == ["add"]):
        return do_comment(argv, stdin_text)
    if head == ["import"]:
        return do_import(argv, stdin_text)
    if head == ["remember"]:
        return do_remember(argv)
    if argv[:2] == ["gate", "create"]:
        return do_gate_create(argv)
    raise NotSupported(" ".join(argv[:2]))
