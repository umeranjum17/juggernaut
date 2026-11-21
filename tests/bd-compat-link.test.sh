#!/usr/bin/env bash
# bd_compat.py in mode tables answers each recorded form of the `link` family from fleet.db with the bytes and exit status bd gave.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
repo=$PWD
forms=$repo/core/item-store/adapters/bd-forms.tsv
t=$(mktemp -d) || exit 1
trap 'rm -rf -- "$t"' EXIT
# A version-manager shim of python3 breaks under a throwaway PATH: link the real interpreter into a folder of its own.
mkdir -p "$t/py"
for _py in /usr/bin/python3 /usr/local/bin/python3 "$(python3 -c 'import sys; print(sys.executable)')"; do [ -x "$_py" ] && { ln -sf "$_py" "$t/py/python3"; break; }; done
export PATH=$t/py:$PATH
fail=0
n_forms=0
for fx in "$repo"/tests/fixtures/bd-forms/*.json; do
  d=$t/case; rm -rf -- "$d"; mkdir -p "$d/home/config"
  python3 -I - "$fx" "$d" "$forms" <<'PY' || continue
import json, sys
fx, d, forms = sys.argv[1:]
f = json.load(open(fx))
fam = {l.split("\t")[0]: l.split("\t")[2] for l in open(forms).read().splitlines() if l.count("\t") >= 3}
if fam.get(f["form"]) != "link":
    sys.exit(1)
open(d + "/form", "w").write(f["form"])
open(d + "/argv", "w").write("\0".join(f["argv"]))
open(d + "/stdin", "w").write(f["stdin"])
open(d + "/stdout", "w").write(f["stdout"])
open(d + "/exit", "w").write(str(f["exit"]))
open(d + "/store.jsonl", "w").write(f["store"])
PY
  form=$(<"$d/form"); n_forms=$((n_forms + 1))
  : >"$d/home/config/bd-tables"
  export JG_HOME=$d/home
  python3 "$repo/core/item-store/adapters/tickets.py" import --home main "$d/store.jsonl" >/dev/null 2>&1
  mapfile -d '' -t args <"$d/argv"
  got=$(PATH=$t/py python3 -I "$repo/core/item-store/adapters/bd_compat.py" "${args[@]}" <"$d/stdin" 2>"$d/err"; echo "rc=$?")
  want=$(cat "$d/stdout"; echo "rc=$(<"$d/exit")")
  if [ "$form" = "delete --force" ]; then
    # bd counted removed events from its own event table, which no export carried: only that one count is masked on both sides.
    got=$(sed -E 's/^  Removed [0-9]+ event\(s\)$/  Removed N event(s)/' <<<"$got") want=$(sed -E 's/^  Removed [0-9]+ event\(s\)$/  Removed N event(s)/' <<<"$want")
  fi
  if [ "$got" = "$want" ]; then echo "ok $form"; else echo "FAIL $form: got [$got] want [$want] $(head -c 200 "$d/err")"; fail=1; fi
done
[ "$n_forms" -gt 0 ] || { echo "FAIL: no fixture of the link family"; fail=1; }
exit "$fail"
