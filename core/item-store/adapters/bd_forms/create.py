"""bd_forms/create.py: the `create` family of bd calls, answered from the ticket tables (fleet.db) in mode `tables`.

  run(argv, stdin_text) -> (stdout_text, exit_status)

Answers `create`: one new row, written through tickets.change (the writer `tickets.py write` uses), so
ticket_change keeps the history. It prints what bd printed: the text block, the --json object or the --silent id line.
A form it cannot answer with bd's exact bytes raises NotSupported: `comment`, `comments add`, `import` and `remember`; `gate create` is routed by bd_compat.py to the `link` family, so slice s5 owns it, (no
table holds a comment, a memory or a file's rows), and a call it has no recorded answer for (a flag it does not know, a missing
parent or dependency, a failed --validate). The reason rule of bin/jg-beads.sh (a deferred row needs a hold reason) is kept:
it refuses with exit 2, as the wrapper did. Python stdlib only."""
import json, os, re, secrets, sys, time

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
    """bin/jg-beads.sh reason_check for a create: a call that defers a row names its hold reason."""
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
                   dependencies=[{"depends_on_id": to, "type": ty} for to, ty in links])
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


def run(argv, stdin_text):
    if argv[:1] == ["create"]:
        return do_create(argv, stdin_text)
    raise NotSupported(" ".join(argv[:2]))
