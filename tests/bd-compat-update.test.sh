#!/usr/bin/env bash
# bd_compat.py in mode tables answers the recorded `update` calls from fleet.db with the bytes and exit status bd gave.
# One scratch home per fixture in tests/fixtures/bd-forms: its store export is imported, then the call is run. No bd, no dolt.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
repo=$PWD
t=$(mktemp -d) || exit 1
trap 'rm -rf -- "$t"' EXIT
mkdir -p "$t/path"
py=; for c in /usr/bin/python3 /usr/local/bin/python3 "$(command -v python3)"; do [ -x "$c" ] && "$c" -c pass 2>/dev/null && { py=$c; break; }; done
[ -n "$py" ] || exit 1
ln -s "$py" "$t/path/python3"          # the one tool on PATH: neither bd nor dolt can run
fail=0
# a fixture counts when its form is a recorded `update` form whose call is the update verb or `gate resolve` (close, defer and the rest are the link family's)
mapfile -t fixtures < <(PATH=$t/path python3 -I - "$repo" <<'PY'
import csv, glob, json, os, sys
repo = sys.argv[1]
forms = {r[0] for r in csv.reader(open(os.path.join(repo, "core/item-store/adapters/bd-forms.tsv")), delimiter="\t") if r[2:3] == ["update"]}
for p in sorted(glob.glob(os.path.join(repo, "tests/fixtures/bd-forms/*.json")), key=lambda p: int(os.path.basename(p)[:-5])):
    d = json.load(open(p))
    if d["form"] in forms and (d["argv"][:1] == ["update"] or d["argv"][:2] == ["gate", "resolve"]):
        print(p)
PY
)
[ "${#fixtures[@]}" -gt 0 ] || { echo "FAIL: no update fixture found"; exit 1; }
for fx in "${fixtures[@]}"; do
  n=$(basename "$fx" .json)
  # fixture 127 was recorded from the stand-in bd of tests/item-store-tickets.test.sh, which prints nothing: no real bd bytes to match
  if [ "$n" = 127 ]; then echo "skip $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["form"])' "$fx") (fixture 127: recorded from a stand-in bd, not bd)"; continue; fi
  h=$t/home-$n
  mkdir -p "$h/config" "$h/state" "$h/data"
  : >"$h/config/bd-tables"
  PATH=$t/path python3 -I - "$fx" "$t/$n" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); base = sys.argv[2]
open(base + ".store", "w", encoding="utf-8").write(d["store"])
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
  PATH=$t/path JG_HOME=$h python3 -I "$repo/core/item-store/adapters/bd_compat.py" "${argv[@]}" <"$t/$n.stdin" >"$t/$n.got" 2>"$t/$n.err"
  rc=$?
  if [ "$rc" = "$(cat "$t/$n.exit")" ] && cmp -s "$t/$n.got" "$t/$n.stdout"; then echo "ok $form"
  else echo "FAIL $form (fixture $n: exit $rc, wanted $(cat "$t/$n.exit"); $(head -1 "$t/$n.err"))"; fail=1; fi
done
exit "$fail"
