#!/usr/bin/env bash
# bd_compat.py in mode `tables` answers every recorded form of the `create` family from fleet.db, with the bytes and the exit
# status bd gave. One `ok <form>` or `FAIL <form>` line per fixture in tests/fixtures/bd-forms whose form has family `create`.
# Each call runs on a scratch home whose fleet.db holds the fixture's store export.
#
# Three things bd decides at call time cannot repeat, so both sides are masked before the compare: the clock (every
# ISO time), and an id bd drew itself (a call with no --id and no --parent: it must have the store's prefix and the
# shape the fixture shows, and must be new). Everything else is compared byte for byte.
#
# OPEN lists forms no table can answer (a named `known-gap <form>: <reason>` line each); it is empty: every recorded
# create form is answered. A form outside OPEN that fails fails the test.
#
# Inputs bd read at call time and the fixture cannot hold are made here: the file a `comments add -f` or an `import` names is
# written on the scratch home (its path in the fixture is another machine's), and a comment's id (a v5 uuid bd derives from the
# call time) is masked, its shape checked. A gate's JSON and text carry the id bd drew, masked as for any create.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
repo=$PWD
t=$(mktemp -d) || exit 1
trap 'rm -rf -- "$t"' EXIT
mkdir -p "$t/py"
for _py in /usr/bin/python3 /usr/local/bin/python3 "$(command -v python3)"; do [ -x "$_py" ] && { ln -sf "$_py" "$t/py/python3"; break; }; done
OPEN=''
PATH=$t/py JG_REPO=$repo JG_SCRATCH=$t JG_OPEN_FORMS=$OPEN "$t/py/python3" -I - <<'PY'
import json, os, re, sqlite3, subprocess, sys

repo, scratch = os.environ["JG_REPO"], os.environ["JG_SCRATCH"]
open_forms = set(os.environ["JG_OPEN_FORMS"].split("\n"))
adapters = os.path.join(repo, "core", "item-store", "adapters")
fixtures = os.path.join(repo, "tests", "fixtures", "bd-forms")
family = {}
for line in open(os.path.join(adapters, "bd-forms.tsv"), encoding="utf-8"):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 3:
        family[p[0]] = p[2]

TIME = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z")


def drawn_id(out):
    """The id a create printed: its JSON id, its --silent line, or the id after 'Created issue:' or 'Created gate'."""
    if out.startswith("{"):
        return json.loads(out).get("id")
    m = re.match(r"(?:✓ Created (?:issue: |gate ))?(\S+)", out)
    return m.group(1) if m else None


def build_home(n, store):
    home = os.path.join(scratch, "home%s" % n)
    for d in ("config", "state", "data"):
        os.makedirs(os.path.join(home, d))
    open(os.path.join(home, "config", "bd-tables"), "w").close()
    rows = [ln for ln in store.splitlines() if ln.strip() and "\"id\"" in ln]
    export = os.path.join(home, "export.jsonl")
    open(export, "w", encoding="utf-8").write("".join(r + "\n" for r in rows))
    env = dict(os.environ, JG_HOME=home, JG_STATE_OVERRIDE=home + "/state", JG_DATA_OVERRIDE=home + "/data", BEADS_ACTOR="main")
    r = subprocess.run(["python3", "-I", os.path.join(adapters, "tickets.py"), "import", "--home", "main", export],
                       capture_output=True, text=True, env=env)
    if r.returncode:
        sys.exit("import failed: " + r.stdout + r.stderr)
    return home, env, [json.loads(x)["id"] for x in rows]


UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
IMPORT_ROW = {"id": "imp-new", "title": "Imported", "status": "open", "priority": 1, "issue_type": "task",
              "created_at": "2026-11-19T10:00:00Z", "updated_at": "2026-11-19T10:00:00Z"}


def prepare(fx, home):
    """The argv to run: a file argument names a file written on the scratch home."""
    argv = list(fx["argv"])
    if argv[:2] == ["comments", "add"] and "-f" in argv:
        path = os.path.join(home, "note.txt")
        open(path, "w", encoding="utf-8").write("a note from a file")
        argv[argv.index("-f") + 1] = path
    elif argv[0] == "remember":     # a store made before the memory table: opening it adds the table
        con = sqlite3.connect(os.path.join(home, "state", "item-store", "fleet.db"))
        con.execute("DROP TABLE memory")
        con.commit()
        con.close()
    elif argv[0] == "import":
        path = os.path.join(home, argv[1])
        open(path, "w", encoding="utf-8").write(json.dumps(IMPORT_ROW) + "\n" + json.dumps({"_type": "memory", "key": "imp", "value": "from import"}) + "\n")
        argv[1] = path
    return argv


def written(con, argv, out):
    """None when the call's write is in the tables, else what is missing."""
    def one(sql, *a):
        return con.execute(sql, a).fetchone()
    verb = argv[0] if argv[0] != "comments" else "comment"
    if verb == "create":
        new = drawn_id(out)
        if not one("SELECT 1 FROM ticket WHERE home = 'main' AND id = ?", new):
            return "no ticket row for %s" % new
        if not one("SELECT 1 FROM ticket_change WHERE home = 'main' AND id = ? AND verb = 'create'", new):
            return "no ticket_change row for %s" % new
    elif verb == "comment":
        want = "a note from a file" if "-f" in argv else None
        row = one("SELECT text FROM comment WHERE home = 'main' AND ticket_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1", argv[2] if argv[0] == "comments" else argv[1])
        if not row or (want and row[0] != want) or not one("SELECT 1 FROM ticket_change WHERE verb = 'comment' AND home = 'main'"):
            return "no comment row (or log row) on the ticket"
    elif verb == "remember":
        if not one("SELECT 1 FROM memory WHERE home = 'main' AND key = ? AND value = ?", argv[argv.index("--key") + 1], argv[1]):
            return "no memory row"
    elif verb == "import":
        if not one("SELECT 1 FROM ticket WHERE home = 'main' AND id = ?", IMPORT_ROW["id"]) or not one("SELECT 1 FROM memory WHERE home = 'main' AND key = 'imp'"):
            return "the imported ticket or memory is not in the tables"
    elif verb == "gate":
        new = drawn_id(out)
        if not one("SELECT 1 FROM ticket WHERE home = 'main' AND id = ? AND issue_type = 'gate'", new):
            return "no gate row for %s" % new
        if not one("SELECT 1 FROM link WHERE home = 'main' AND from_id = ? AND to_id = ? AND type = 'blocks'", argv[argv.index("--blocks") + 1], new):
            return "the blocked ticket holds no link to %s" % new
    return None


def judge(fx, home, env, ids):
    argv, want_out, want_rc = prepare(fx, home), fx["stdout"], fx["exit"]
    author = re.search(r'"author": "([^"]*)"', want_out)     # the actor the call ran as, an environment input
    run = subprocess.run(["python3", "-I", os.path.join(adapters, "bd_compat.py")] + argv, input=fx["stdin"],
                         capture_output=True, text=True, env=dict(env, BEADS_ACTOR=author.group(1)) if author else env)
    if run.returncode == 2 and "form not supported" in run.stderr:
        return "not supported"
    got = run.stdout
    if want_rc == 0 and run.returncode == 0 and argv[0] in ("create", "gate") and "--id" not in argv and "--parent" not in argv:
        a, e = drawn_id(got), drawn_id(want_out)
        prefix = (e or "").rsplit("-", 1)[0] + "-"
        if a and e and a.startswith(prefix) and len(a) == len(e) and a not in ids and re.fullmatch(r"[0-9a-z]+", a[len(prefix):]):
            got, want_out = got.replace(a, "<id>"), want_out.replace(e, "<id>")
    if want_rc == 0 and UUID.search(want_out):      # a comment's id: a v5 uuid of the call time
        if not UUID.search(got):
            return "no comment id in the answer"
        got, want_out = UUID.sub("<uuid>", got), UUID.sub("<uuid>", want_out)
    got, want_out = TIME.sub("<time>", got), TIME.sub("<time>", want_out)
    if run.returncode != want_rc:
        return "exit %d, want %d (%s)" % (run.returncode, want_rc, run.stderr.strip()[:200])
    if got != want_out:
        return "stdout differs\n--- got\n%s\n--- want\n%s" % (got[:600], want_out[:600])
    if want_rc == 0:  # what the call wrote is in the tables, with its log row
        con = sqlite3.connect(os.path.join(home, "state", "item-store", "fleet.db"))
        return written(con, argv, run.stdout)
    return None


bad = 0
for name in sorted(os.listdir(fixtures), key=lambda s: int(s.split(".")[0])):
    fx = json.load(open(os.path.join(fixtures, name), encoding="utf-8"))
    form = fx["form"]
    if family.get(form) != "create":
        continue
    home, env, ids = build_home(name.split(".")[0], fx["store"])
    why = judge(fx, home, env, ids)
    if why is None and form not in open_forms:
        print("ok %s" % form)
    elif form in open_forms and why == "not supported":
        print("known-gap %s: no table holds it" % form)
    else:
        print("FAIL %s: %s" % (form, why or "answered, but it is listed open"))
        bad = 1
sys.exit(bad)
PY
