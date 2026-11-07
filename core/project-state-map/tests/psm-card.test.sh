#!/usr/bin/env bash
# Host test table for psm-card.sh: the card drawn from the proved fixture map.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
card=$here/../bin/psm-card.sh
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
fail=0
want() { # want <label> <got> <expected>
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got $2 want $3"; fail=1; fi
}
T=2026-11-07T10:00:00Z
bash "$here/../bin/psm-prove.sh" "$here/fixture-map.json" "$here/fixture-project" --out "$d/proved.json"

bash "$card" "$d/proved.json" --out-dir "$d/a" --filed "$T"
bash "$card" "$d/proved.json" --out-dir "$d/b" --filed "$T"
want 'same map gives the same card and pictures' "$(cd "$d/a" && find . -type f | sort | xargs sha256sum | sha256sum)" "$(cd "$d/b" && find . -type f | sort | xargs sha256sum | sha256sum)"
want 'card is a schema 5 report in the State map group' "$(jq -r '"\(.kind) \(.schema) \(.group) \(.key)"' "$d/a/report.json")" 'report 5 State map state-map-fixture-project-fixture'
want 'the title counts machines and parts' "$(jq -r .title "$d/a/report.json")" 'fixture-project has 3 state machines and 2 moving parts'
want 'one picture per kind, all present' "$(jq -r '.visual.diagram[] | .label' "$d/a/report.json" | paste -sd,)" 'Explicit sets,Hidden states,Machinery'
want 'every picture the card names exists' "$(jq -r '.visual.diagram[].src' "$d/a/report.json" | while read -r s; do [ -s "$d/a/$s" ] && echo ok; done | paste -sd,)" 'ok,ok,ok'
want 'dropped lines are counted on the card' "$(jq -r '.visual.rows[] | select(.label == "Lines dropped") | "\(.value) \(.tone)"' "$d/a/report.json")" '7 warn'
want 'a state set shows its states' "$(jq -r '.sections[0].items[0] | "\(.title) | \(.text)"' "$d/a/report.json")" 'Ticket stage has 4 states | queued, working, review, done'
want 'the dropped false machine is not on the card' "$(grep -c 'Phantom retry' "$d/a/report.json" || true)" '0'
want 'the picture draws the moves the map has' "$(grep -o 'marker-end' "$d/a/state-map/state-map-fixture-project-fixture/explicit.html" | wc -l)" '3'

# A map with no hidden states and no parts draws only the pictures it has.
jq '.machines |= map(select(.kind == "explicit")) | .machinery = []' "$d/proved.json" > "$d/small.json"
bash "$card" "$d/small.json" --out-dir "$d/s" --filed "$T"
want 'only the pictures the map has' "$(jq -r '.visual.diagram[].label' "$d/s/report.json" | paste -sd,)" 'Explicit sets'
want 'no stale picture file left' "$(ls "$d/s/state-map/state-map-fixture-project-fixture")" 'explicit.html'
want 'an edited map gives a different card' "$([ "$(sha256sum < "$d/s/report.json")" != "$(sha256sum < "$d/a/report.json")" ] && echo differs)" 'differs'

# Post: the card and its pictures go to the board folder, then the replaced card is dismissed.
mkdir -p "$d/board"; printf '#!/usr/bin/env bash\necho "$@" >> %s/calls\n' "$d" > "$d/post"; chmod +x "$d/post"
JG_REPORT_POST=$d/post bash "$card" "$d/proved.json" --out-dir "$d/p" --filed "$T" --post "$d/board/b.json" --replaces state-map-old
want 'post then dismiss the replaced card' "$(sed 's|[^ ]*/board/b.json|BOARD|; s|[^ ]*/p/report.json|CARD|' "$d/calls" | paste -sd'|')" 'post BOARD --kind report --from CARD --filer project-state-map|dismiss BOARD state-map-old'
want 'pictures are copied beside the board' "$(cd "$d/board/state-map/state-map-fixture-project-fixture" && printf '%s\n' * | paste -sd,)" 'explicit.html,hidden.html,machinery.html'

# The real board accepts the card when sign-off-axi is installed.
if command -v sign-off-axi >/dev/null; then
  mkdir -p "$d/rb/.sign-off"; (cd "$d/rb" && SIGN_OFF_HOME=$d/rb sign-off-axi init >/dev/null 2>&1)
  if bash "$card" "$d/proved.json" --out-dir "$d/r" --filed "$T" --post "$d/rb/.sign-off/decisions.json" >/dev/null 2>"$d/err"; then echo 'PASS the board accepts the card'; else echo "FAIL the board refused the card: $(head -c 300 "$d/err")"; fail=1; fi
else echo 'SKIP the board accepts the card (sign-off-axi not installed)'; fi

# Bad input says what is wrong.
want 'a map that is not proved is refused' "$(bash "$card" "$here/fixture-map.json" --out-dir "$d/x" 2>&1 >/dev/null || true)" "psm-card: not a psm.proved.v1 map: $here/fixture-map.json"
want 'replaces without post is refused' "$(bash "$card" "$d/proved.json" --out-dir "$d/x" --replaces k 2>&1 >/dev/null || true)" 'psm-card: --replaces needs --post'
want 'unknown argument refused' "$(bash "$card" "$d/proved.json" --out-dir "$d/x" --bogus 2>&1 >/dev/null || true)" 'psm-card: unknown argument --bogus'
exit "$fail"
