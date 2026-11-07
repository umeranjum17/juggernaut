#!/usr/bin/env bash
# Host test table for psm-refresh.sh ask: a person asks for a fresh map; unchanged code says so, force reruns.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
refresh=$here/../bin/psm-refresh.sh
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
fail=0
want() { # want <label> <got> <expected>
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got $2 want $3"; fail=1; fi
}
{ echo '```json'; jq -c '{machines, machinery, not_read}' "$here/fixture-map.json"; echo '```'; } > "$d/reply.txt"
printf '#!/usr/bin/env bash\ncat > /dev/null; echo x >> %s/model-calls; cat %s/reply.txt\n' "$d" "$d" > "$d/model"
printf '#!/usr/bin/env bash\necho "$*" >> %s/board-calls\n' "$d" > "$d/post"
chmod +x "$d/model" "$d/post"; : > "$d/model-calls"; : > "$d/board-calls"
export PSM_READ_COMMAND=$d/model JG_REPORT_POST=$d/post
calls() { wc -l < "$d/model-calls" | tr -d ' '; }
cp -r "$here/fixture-project" "$d/proj"; mkdir -p "$d/home/config"
printf '%s\n' "$d/board.json" > "$d/home/config/fleet-board"
printf '%s opt-in\n' "$d/proj" > "$d/home/config/project-state-map"
ask() { bash "$refresh" ask "$d/home" "$@"; }

out=$(ask proj)
want 'the first ask by project name makes a card' "$(printf '%s\n' "$out" | grep -c '^refreshed: proj card state-map-proj-') $(calls)" '1 1'
card=$(cat "$d/home/state/project-state-map/proj/card-key")
want 'the answer names the current card' "$(printf '%s\n' "$out" | tail -1)" "current card: $card"
out=$(ask proj)
want 'a second ask on the same code says unchanged and names the card' "$(printf '%s\n' "$out" | sed 's/(tree [0-9a-f]*)/(tree T)/' | paste -sd'|')" "unchanged: proj (tree T)|current card: $card"
want 'the second ask made no model call and no post' "$(calls) $(wc -l < "$d/board-calls" | tr -d ' ')" '1 1'
sleep 1; out=$(ask "$d/proj" --force)
want 'force by directory reruns and replaces the card' "$(calls) $(printf '%s\n' "$out" | grep -c '^refreshed: ') $([ "$(cat "$d/home/state/project-state-map/proj/card-key")" != "$card" ] && echo new)" '2 1 new'
want 'force dismisses the old card' "$(grep -c "^dismiss .* $card$" "$d/board-calls")" '1'
rc=0; ask nothere >/dev/null 2>&1 || rc=$?; want 'an unknown project is refused with exit 2' "$rc" '2'
printf '%s\n' "$d/proj" > "$d/home/config/project-state-map"; rm -rf "$d/home/state"
rc=0; out=$(ask proj 2>&1) || rc=$?
want 'a project without the opt-in word is refused before any call' "$rc $(calls) $(printf '%s' "$out" | grep -c 'opt-in')" '3 2 1'
want 'the opt-in flag on the ask allows it' "$(ask proj --opt-in | grep -c '^refreshed: ')" '1'
rm -f "$d/home/config/fleet-board"; rc=0; ask proj >/dev/null 2>&1 || rc=$?
want 'no board is refused with exit 4' "$rc" '4'
exit "$fail"
