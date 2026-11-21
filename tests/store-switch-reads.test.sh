#!/usr/bin/env bash
# The ticket tables answer two reads:
#   1 bd_compat.py's `list --json` and `list --all --json` on a home with no rows print `[]` (a reader parses it; nothing broke jq);
#   2 `jg-backlog.sh ready --spawnable` names the startable rows of the tables (it once fell back to a store it no longer has).
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
repo=$PWD
t=$(mktemp -d) || exit 1
trap 'rm -rf -- "$t"' EXIT
fail=0
home() { mkdir -p "$1/config" "$1/state" "$1/data"; }
at() { local h=$1; shift; (cd "$h" && env JG_HOME="$h" JG_DATA_OVERRIDE="$h/data" JG_STATE_OVERRIDE="$h/state" "$@"); }

home "$t/empty"
for form in "list --json" "list --all --json"; do
  # shellcheck disable=SC2086
  out=$(at "$t/empty" python3 -I "$repo/core/item-store/adapters/bd_compat.py" $form </dev/null); rc=$?
  if [ "$rc" = 0 ] && [ "$out" = "[]" ]; then echo "ok: $form on a home with no rows prints []"; else echo "FAIL: $form rc=$rc out=[$out]"; fail=1; fi
done

home "$t/rows"
printf -- '- p\n' > "$t/rows/data/projects.md"
JG_HOME=$t/rows python3 -I "$repo/core/item-store/adapters/tickets.py" import --home main "$repo/tests/fixtures/item-store-tickets/export.jsonl" >/dev/null \
  || { echo "FAIL: the fixture does not import"; exit 1; }
out=$(at "$t/rows" "$repo/bin/jg-backlog.sh" ready --spawnable 2>&1); rc=$?
want=$(printf 'count: 4\njg-ready1\tp\njg-unres\tp\njg-child\tp\njg-rel\tp')
if [ "$rc" = 0 ] && [ "$out" = "$want" ]; then echo "ok: ready --spawnable reads the tables"; else echo "FAIL: ready --spawnable rc=$rc out=$out"; fail=1; fi
: > "$t/rows/state/jg-ready1.meta"
out=$(at "$t/rows" "$repo/bin/jg-backlog.sh" ready --spawnable 2>&1)
case $out in "count: 3"*) case $out in *jg-ready1*) echo "FAIL: a live lane's row is named: $out"; fail=1 ;; *) echo "ok: a row a live lane holds is left out" ;; esac ;;
  *) echo "FAIL: live lane: $out"; fail=1 ;; esac
exit "$fail"
