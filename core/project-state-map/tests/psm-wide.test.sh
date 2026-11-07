#!/usr/bin/env bash
# Host test table for psm-wide-check.sh: a wide report needs the map, a narrow one does not, a week of warning comes first.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
check=$here/../bin/psm-wide-check.sh
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
fail=0
want() { # want <label> <got> <expected>
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got $2 want $3"; fail=1; fi
}
mkdir -p "$d/state/project-state-map/proj" "$d/config"
bash "$here/../bin/psm-prove.sh" "$here/fixture-map.json" "$here/fixture-project" --out "$d/state/project-state-map/proj/proved.json"
echo state-map-proj-1a2b3c4d-1700000000 > "$d/state/project-state-map/proj/card-key"
printf '# Findings\n\nThe Ticket stage, the Gate state and the Board poll all misbehave.\n' > "$d/wide.md"
printf '# Findings\n\nOnly the Stuck flag is wrong.\n' > "$d/narrow.md"
chk() { PSM_NOW=${NOW:-1700000000} bash "$check" "$1" --project proj --state "$d/state" --config "$d/config"; }
code() { local rc=0; chk "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

want 'a report naming one area passes' "$(chk "$d/narrow.md" | cut -c1-5)" 'PASS:'
want 'two areas is still narrow' "$(printf 'The ticket-stage and gate state.\n' > "$d/two.md"; chk "$d/two.md" | cut -c1-5)" 'PASS:'
w=$(chk "$d/wide.md" 2>&1)
want 'a wide report with no map is warned in the first week and still passes' "$(printf '%s' "$w" | cut -c1-5) $(code "$d/wide.md")" 'WARN: 0'
want 'the warning names the areas and the card to add' "$(printf '%s' "$w" | grep -c 'Ticket stage, Gate state, Board poll.*state-map-proj-1a2b3c4d')" '1'
want 'the first check starts the week' "$(cat "$d/state/project-state-map/wide-since")" '1700000000'
NOW=$((1700000000 + 8 * 86400)); export NOW
want 'a wide report with no map is refused after a week' "$(chk "$d/wide.md" 2>&1 | cut -c1-8) $(code "$d/wide.md")" 'REFUSED: 1'
printf 'warn\n' > "$d/config/project-state-map-wide"
want 'the warn-only switch keeps it at a warning' "$(code "$d/wide.md") $(chk "$d/wide.md" 2>&1 | cut -c1-5)" '0 WARN:'
rm "$d/config/project-state-map-wide"
cp "$d/wide.md" "$d/withkey.md"; echo 'Map: state-map-proj-1a2b3c4d-1700000000' >> "$d/withkey.md"
want 'a wide report with the map card passes after a week' "$(chk "$d/withkey.md" | cut -c1-5) $(code "$d/withkey.md")" 'PASS: 0'
cp "$d/wide.md" "$d/withsec.md"; printf '\n## State map\n\nSee the card.\n' >> "$d/withsec.md"
want 'a wide report with a State map section passes' "$(code "$d/withsec.md")" '0'
printf '## 2. State map\n' > "$d/numbered.md"; cat "$d/wide.md" >> "$d/numbered.md"
want 'a numbered State map heading passes too' "$(code "$d/numbered.md")" '0'
want 'the narrow report still passes after a week' "$(code "$d/narrow.md")" '0'
printf 'The ticket-stage, gate-state and stuck-flag machines.\n' > "$d/ids.md"
want 'names are matched by id too' "$(code "$d/ids.md")" '1'
want 'a project with no stored map is skipped' "$(PSM_NOW=1 bash "$check" "$d/wide.md" --project other --state "$d/state" | cut -c1-5)" 'SKIP:'
rc=0; bash "$check" "$d/none.md" --project proj --state "$d/state" >/dev/null 2>&1 || rc=$?
want 'a missing report is a usage error' "$rc" '2'
exit "$fail"
