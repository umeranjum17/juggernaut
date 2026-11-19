#!/usr/bin/env bash
# policy.py --import reads every lead home's registry too: a project only in a lead home gets a row, a project in two
# registries with different modes prints the conflict and keeps the main home's row, a second run changes nothing.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
POLICY=$HERE/../adapters/policy.py
d=$(mktemp -d) || exit 1
trap 'rm -rf -- "$d"' EXIT
H=$d/main L1=$d/lead1 L2=$d/lead2
mkdir -p "$H/data" "$H/state" "$L1/data" "$L2/data"
printf -- '- alpha [direct-PR]\n- beta [local-trunk]\n' > "$H/data/projects.md"
printf -- '- gamma [no-mistakes +yolo]\n- beta [local-trunk]\n' > "$L1/data/projects.md"
printf -- '- delta [local-trunk]\n- alpha [local]\n' > "$L2/data/projects.md"
{
  printf -- '- lead1 - first lead (home: %s; scope: one; projects: gamma; added 2026-10-31)\n' "$L1"
  printf -- '- lead2 - second lead (home: %s; scope: two; projects: delta; added 2026-10-31)\n' "$L2"
} > "$H/data/squad_leads.md"
fail=0
ok()  { echo "ok $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }
pol() { JG_HOME="$H" python3 -I "$POLICY" "$@" 2>&1; }
row() { pol --row "$1"; }

out=$(pol --import); rc=$?
[ "$rc" -eq 0 ] && ok import-exit || bad import-exit "exit $rc: $out"
case $out in *conflict*alpha*) ok conflict-printed ;; *) bad conflict-printed "[$out]" ;; esac
[ "$(printf "%s\n" "$out" | grep -c "^conflict ")" -eq 1 ] && ok same-mode-no-conflict || bad same-mode-no-conflict "[$out]"
[ "$(row gamma)" = "mode=direct-PR level=loose merge=machine land=machine release=machine lanes=16 trunk=main" ] && ok lead-only-gamma || bad lead-only-gamma "[$(row gamma)]"
case $(row delta) in "mode=local-trunk level=standard "*) ok lead-only-delta ;; *) bad lead-only-delta "[$(row delta)]" ;; esac
case $(row alpha) in "mode=direct-PR level=tight "*) ok main-row-kept ;; *) bad main-row-kept "[$(row alpha)]" ;; esac
[ "$(printf '%s\n' "$out" | grep -c '^beta	')" -eq 1 ] && ok each-project-once || bad each-project-once "[$out]"

before=$(sqlite3 "$H/state/item-store/fleet.db" 'SELECT project, version, mode, level FROM policy ORDER BY 1, 2' 2>&1)
pol --import >/dev/null; rc=$?
after=$(sqlite3 "$H/state/item-store/fleet.db" 'SELECT project, version, mode, level FROM policy ORDER BY 1, 2' 2>&1)
[ "$rc" -eq 1 ] && [ "$before" = "$after" ] && [ -n "$before" ] && ok second-run-changes-nothing || bad second-run-changes-nothing "exit $rc; [$before] vs [$after]"
exit "$fail"
