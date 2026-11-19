#!/usr/bin/env bash
# bd_compat.py in mode `tables` answers every recorded form of the `create` family from fleet.db, with the bytes and the exit
# status bd gave. One `ok <form>` or `FAIL <form>` line per fixture in tests/fixtures/bd-forms whose form has family `create`.
# Each call runs on a scratch home whose fleet.db holds the fixture's store export. No bd and no dolt run: PATH holds neither.
#
# Three things bd decides at call time cannot repeat, so both sides are masked before the compare: the clock (every
# ISO time), and an id bd drew itself (a call with no --id and no --parent: it must have the store's prefix and the
# shape the fixture shows, and must be new). Everything else is compared byte for byte.
#
# OPEN lists forms this module does not answer: a comment, a memory and a file import have no table (the comment table comes
# with slice s1), and bd_compat.py routes `gate create` to the `link` family, whose slice s5 owns it. They must answer
# "form not supported" (exit 2) and print FAIL; they never fake an answer. A form outside OPEN that fails fails the test.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
repo=$PWD
t=$(mktemp -d) || exit 1
trap 'rm -rf -- "$t"' EXIT
mkdir -p "$t/py"
for _py in /usr/bin/python3 /usr/local/bin/python3 "$(command -v python3)"; do [ -x "$_py" ] && { ln -sf "$_py" "$t/py/python3"; break; }; done
OPEN=$'comment\ncomment --json --stdin\ncomments add -f\nimport\nremember --key\ngate create --blocks --json --reason --title --type\ngate create --blocks --reason --title'
PATH=$t/py JG_REPO=$repo JG_SCRATCH=$t JG_OPEN_FORMS=$OPEN "$t/py/python3" -I - <<'PY'
import json, os, re, shutil, sqlite3, subprocess, sys

repo, scratch = os.environ["JG_REPO"], os.environ["JG_SCRATCH"]
open_forms = set(os.environ["JG_OPEN_FORMS"].split("\n"))
adapters = os.path.join(repo, "core", "item-store", "adapters")
fixtures = os.path.join(repo, "tests", "fixtures", "bd-forms")
family = {}
for line in open(os.path.join(adapters, "bd-forms.tsv"), encoding="utf-8"):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 3:
        family[p[0]] = p[2]
for tool in ("bd", "dolt"):
    if shutil.which(tool, path=os.environ["PATH"]):
        sys.exit("the test PATH must hold no %s" % tool)

TIME = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z")


def drawn_id(out):
    """The id a create printed: its JSON id, its --silent line, or the id after 'Created issue:' or 'Created gate'."""
    if out.startswith("{"):
        return json.loads(out).get("id")
    m = re.match(r"(?:✓ Created (?:issue|gate): )?(\S+)", out)
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


def judge(fx, home, env, ids):
    argv, want_out, want_rc = fx["argv"], fx["stdout"], fx["exit"]
    run = subprocess.run(["python3", "-I", os.path.join(adapters, "bd_compat.py")] + argv, input=fx["stdin"],
                         capture_output=True, text=True, env=env)
    if run.returncode == 2 and "form not supported" in run.stderr:
        return "not supported"
    got = run.stdout
    if want_rc == 0 and run.returncode == 0 and "--id" not in argv and "--parent" not in argv:
        a, e = drawn_id(got), drawn_id(want_out)
        prefix = (e or "").rsplit("-", 1)[0] + "-"
        if a and e and a.startswith(prefix) and len(a) == len(e) and a not in ids and re.fullmatch(r"[0-9a-z]+", a[len(prefix):]):
            got, want_out = got.replace(a, "<id>"), want_out.replace(e, "<id>")
    got, want_out = TIME.sub("<time>", got), TIME.sub("<time>", want_out)
    if run.returncode != want_rc:
        return "exit %d, want %d (%s)" % (run.returncode, want_rc, run.stderr.strip()[:200])
    if got != want_out:
        return "stdout differs\n--- got\n%s\n--- want\n%s" % (got[:600], want_out[:600])
    if want_rc == 0:  # the new row is in the tables, with its log row
        new = drawn_id(run.stdout)
        con = sqlite3.connect(os.path.join(home, "state", "item-store", "fleet.db"))
        if not con.execute("SELECT 1 FROM ticket WHERE home = 'main' AND id = ?", (new,)).fetchone():
            return "no ticket row for %s" % new
        if not con.execute("SELECT 1 FROM ticket_change WHERE home = 'main' AND id = ? AND verb = 'create'", (new,)).fetchone():
            return "no ticket_change row for %s" % new
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
        print("FAIL %s (open: no table holds it)" % form)
    else:
        print("FAIL %s: %s" % (form, why or "answered, but it is listed open"))
        bad = 1
sys.exit(bad)
PY
