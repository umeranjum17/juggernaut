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
# Forms the tables cannot answer yet. bd_forms/read.py raises NotSupported for them (or the dispatcher cannot route the call),
# so each prints FAIL here without failing the test; a new FAIL outside this list does. Why:
#   a ticket with a link (edge created_at, created_by, metadata are not kept): list/ready/export forms over linked rows;
#   a gate row (await_type is not kept); a nested metadata object (the tables keep its keys sorted, bd keeps insertion order);
#   events, history and provenance that no ticket_event row records; schema, memories, q and provenance record (no table);
#   check (the admin family answers it), swarm validate and comments <id> (the dispatcher reads them as another verb), --readonly
#   (the dispatcher reads it as the verb), export and bare `list --json` of an empty store (the recorded store does not match).
GAPS=(
  'check'
  'comments'
  'comments --json'
  'events --limit --since'
  'export'
  'history --events'
  'history --events --json'
  'list --all --include-gates --json --limit --readonly'
  'list --all --json'
  'list --all --json --parent'
  'list --include-gates --json --limit --status'
  'list --json'
  'list --json --label --type'
  'list --json --limit'
  'list --json --parent'
  'list --json --parent --status'
  'memories --json'
  'provenance --actor --at --issue --kind --ref --ref-kind --source'
  'provenance --at --issue --kind --payload --ref --ref-kind --source'
  'provenance --at --issue --kind --payload --source'
  'provenance --at --issue --kind --ref --ref-kind --source'
  'provenance --json'
  'q'
  'ready --json --parent'
  'schema'
  'swarm validate'
)
is_gap() { local g; for g in "${GAPS[@]}"; do [ "$g" = "$1" ] && return 0; done; return 1; }
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
import json, sys
d = json.load(open(sys.argv[1])); base = sys.argv[2]
open(base + ".store", "w", encoding="utf-8").write(d["store"] or "")
open(base + ".stdin", "w", encoding="utf-8", newline="").write(d["stdin"])
open(base + ".stdout", "w", encoding="utf-8", newline="").write(d["stdout"])
open(base + ".exit", "w").write(str(d["exit"]))
open(base + ".argv", "wb").write(b"".join(a.encode() + b"\0" for a in d["argv"]))
open(base + ".form", "w").write(d["form"])
PY
  form=$(cat "$t/$n.form")
  mapfile -d '' -t argv <"$t/$n.argv"
  if ! PATH=$t/path JG_HOME=$h python3 -I "$repo/core/item-store/adapters/tickets.py" import --home main "$t/$n.store" >/dev/null 2>"$t/$n.err"; then
    echo "FAIL $form (import: $(head -1 "$t/$n.err"))"; fail=1; continue
  fi
  (cd "$t" && PATH=$t/path JG_HOME=$h python3 -I "$repo/core/item-store/adapters/bd_compat.py" "${argv[@]}" <"$t/$n.stdin" >"$t/$n.got" 2>"$t/$n.err")   # from the scratch folder: export -o writes a file there
  rc=$?
  sed -z 's/,\n *"revision": "[^"]*"//' "$t/$n.got" >"$t/$n.got2"; sed -z 's/,\n *"revision": "[^"]*"//' "$t/$n.stdout" >"$t/$n.want2"
  if [ "$rc" = "$(cat "$t/$n.exit")" ] && cmp -s "$t/$n.got2" "$t/$n.want2"; then echo "ok $form"
  elif is_gap "$form"; then echo "FAIL $form (fixture $n: known gap; exit $rc, wanted $(cat "$t/$n.exit"))"
  else echo "FAIL $form (fixture $n: exit $rc, wanted $(cat "$t/$n.exit"); $(head -1 "$t/$n.err"))"; fail=1; fi
done
exit "$fail"
