#!/usr/bin/env bash
# bd_compat.py in mode tables answers the recorded `read` calls from fleet.db with the bytes and exit status bd gave.
# One scratch home per fixture in tests/fixtures/bd-forms: its store export is imported, then the call is run. No bd, no dolt.
# A `show --json` row ends with a Dolt `revision` hash of the row's content: not derivable from the tables, so the module
# prints no `revision` and the test cuts that key from bd's recorded bytes before comparing.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
repo=$PWD
t=$(mktemp -d) || exit 1
trap 'rm -rf -- "$t"' EXIT
mkdir -p "$t/path"
py=; for c in /usr/bin/python3 /usr/local/bin/python3 "$(command -v python3)"; do [ -x "$c" ] && "$c" -c pass 2>/dev/null && { py=$c; break; }; done
[ -n "$py" ] || exit 1
ln -s "$py" "$t/path/python3"          # the one tool on PATH: neither bd nor dolt can run
fail=0
# Forms no table can answer: each prints `known-gap <form>: <reason>` without failing the test; any other mismatch fails.
declare -A GAPS=(
  ['check']='bd printed the paths and versions of the machine it ran on; the admin family answers check from the tables'
  ['comments']="bd renders a comment's text through a terminal markdown renderer (wrap and padding are not derivable)"
)
# Seeds, as the tables hold them (a store export row may carry `events` and `provenance` arrays; memory has a row per key):
#   export and its recorded store is empty: the recorded stdout is itself an export, so it is the store;
#   history, events and provenance log: the entries of bd's recorded answer, put on the ticket the call names;
#   memories: the recorded key and value, put in the memory table.
# Beads' own random ids (a provenance entry's uuid, the id q mints) are cut from both sides; the `revision` hash of a show row is cut too;
# bd lists the dependencies of a row with several edges in a random order, so two answers that differ in that order alone are equal (so is a blocked row's blocked_by list).
mapfile -t fixtures < <(PATH=$t/path python3 -I - "$repo" <<'PY'
import csv, glob, json, os, sys
repo = sys.argv[1]
forms = {r[0] for r in csv.reader(open(os.path.join(repo, "core/item-store/adapters/bd-forms.tsv")), delimiter="\t") if r[2:3] == ["read"]}
for p in sorted(glob.glob(os.path.join(repo, "tests/fixtures/bd-forms/*.json")), key=lambda p: int(os.path.basename(p)[:-5])):
    if json.load(open(p))["form"] in forms:
        print(p)
PY
)
[ "${#fixtures[@]}" -gt 0 ] || { echo "FAIL: no read fixture found"; exit 1; }
for fx in "${fixtures[@]}"; do
  n=$(basename "$fx" .json)
  h=$t/home-$n
  mkdir -p "$h/config" "$h/state" "$h/data"
  : >"$h/config/bd-tables"
  PATH=$t/path python3 -I - "$fx" "$t/$n" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1])); base = sys.argv[2]
form, argv, store, out = d["form"], d["argv"], d["store"] or "", d["stdout"]
memory = {}
def attach(ident, key, entries):
    global store
    rows = [json.loads(l) for l in store.splitlines() if l.strip()]
    for r in rows:
        if r["id"] == ident:
            r[key] = entries
    store = "".join(json.dumps(r, separators=(",", ":")) + "\n" for r in rows)
if form == "export" and not store:
    store = out
elif form == "history --events --json":
    attach(argv[1], "events", json.loads(out))
elif form == "history --events":
    entries = []
    for block in out.split("\n\n")[1:]:
        lines = block.strip("\n").split("\n")
        if not lines or not lines[0]:
            continue
        date, clock, kind, _, actor = lines[0].split(" ")
        e = {"id": "e%d" % len(entries), "issue_id": argv[1], "event_type": kind, "actor": actor, "created_at": date + "T" + clock + "Z"}
        for line in lines[1:]:
            label, _, text = line.strip().partition(": ")
            e[{"Old": "old_value", "New": "new_value", "Comment": "comment"}[label]] = text
        entries.append(e)
    attach(argv[1], "events", entries)
elif form == "events --limit --since":
    for line in out.splitlines():
        e = json.loads(line)
        attach(e["issue_id"], "events", [e])
elif form == "provenance --json":
    attach(argv[2], "provenance", json.loads(out))
elif form == "memories --json":
    memory = {k: v for k, v in json.loads(out).items() if k != "schema_version"}
open(base + ".store", "w", encoding="utf-8").write(store)
open(base + ".memory", "w", encoding="utf-8").write(json.dumps(memory))
open(base + ".stdin", "w", encoding="utf-8", newline="").write(d["stdin"])
open(base + ".stdout", "w", encoding="utf-8", newline="").write(out)
open(base + ".exit", "w").write(str(d["exit"]))
open(base + ".argv", "wb").write(b"".join(a.encode() + b"\0" for a in argv))
open(base + ".form", "w").write(form)
PY
  form=$(cat "$t/$n.form")
  mapfile -d '' -t argv <"$t/$n.argv"
  if ! PATH=$t/path JG_HOME=$h python3 -I "$repo/core/item-store/adapters/tickets.py" import --home main "$t/$n.store" >/dev/null 2>"$t/$n.err"; then
    echo "FAIL $form (import: $(head -1 "$t/$n.err"))"; fail=1; continue
  fi
  PATH=$t/path JG_HOME=$h python3 -I - "$t/$n.memory" <<'PY'
import glob, json, os, sqlite3, sys
mem = json.load(open(sys.argv[1]))
if mem:
    con = sqlite3.connect(glob.glob(os.environ["JG_HOME"] + "/state/item-store/fleet.db")[0])
    con.executemany("INSERT INTO memory (home, key, value) VALUES ('main', ?, ?)", sorted(mem.items()))
    con.commit()
PY
  (cd "$t" && PATH=$t/path JG_HOME=$h python3 -I "$repo/core/item-store/adapters/bd_compat.py" "${argv[@]}" <"$t/$n.stdin" >"$t/$n.got" 2>"$t/$n.err")   # from the scratch folder: export -o writes a file there
  rc=$?
  PATH=$t/path python3 -I - "$form" "$t/$n.got" "$t/$n.stdout" >"$t/$n.same" <<'PY'
import json, re, sys
form, got, want = sys.argv[1], open(sys.argv[2], encoding="utf-8", newline="").read(), open(sys.argv[3], encoding="utf-8", newline="").read()
cut = lambda t: re.sub(r',\n *"revision": "[^"]*"', "", t)
if form.startswith("provenance --") and form != "provenance --json":
    cut = lambda t: re.sub(r"[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}", "<uuid>", t)
elif form == "q":
    cut = lambda t: re.sub(r"^[a-z0-9]+-[0-9a-z]+$", "<id>", t, flags=re.M)
got, want = cut(got), cut(want)
def parsed(t):
    try:
        v = json.loads(t)
    except ValueError:
        try:
            v = [json.loads(l) for l in t.splitlines()]
        except ValueError:
            return None
    for row in (v if isinstance(v, list) else []):
        if isinstance(row, dict) and isinstance(row.get("dependencies"), list):
            row["dependencies"].sort(key=lambda d: (d["depends_on_id"], d["type"]))
        if isinstance(row, dict) and isinstance(row.get("blocked_by"), list):
            row["blocked_by"].sort()
    return v
print("same" if got == want or (parsed(got) is not None and parsed(got) == parsed(want)) else "differ")
PY
  if [ "$rc" = "$(cat "$t/$n.exit")" ] && [ "$(cat "$t/$n.same")" = same ]; then
    if [[ $form == provenance\ --* && $form != 'provenance --json' ]]; then
      [ "$(PATH=$t/path JG_HOME=$h python3 -I - <<'PY'
import glob, os, sqlite3
print(sqlite3.connect(glob.glob(os.environ["JG_HOME"] + "/state/item-store/fleet.db")[0]).execute("SELECT count(*) FROM ticket_event WHERE source = 'provenance'").fetchone()[0])
PY
)" = 1 ] || { echo "FAIL $form (the recorded entry is not in ticket_event)"; fail=1; continue; }
    fi
    echo "ok $form"
  elif [ -n "${GAPS[$form]:-}" ]; then echo "known-gap $form: ${GAPS[$form]}"
  else echo "FAIL $form (fixture $n: exit $rc, wanted $(cat "$t/$n.exit"); $(head -1 "$t/$n.err"))"; fail=1; fi
done
exit "$fail"
