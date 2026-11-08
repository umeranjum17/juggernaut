#!/usr/bin/env bash
# Host test table for the first run: every project in config/project-state-map that has the opt-in word gets a card, the rest are named.
# Uses copies of the fixture project only; no private project is read and the model is a stub.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
refresh=$here/../bin/psm-refresh.sh
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
fail=0
want() { # want <label> <got> <expected>
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got $2 want $3"; fail=1; fi
}
{ echo '```json'; jq -c '{machines, machinery, not_read}' "$here/fixture-map.json"; echo '```'; } > "$d/reply.txt"
printf '#!/usr/bin/env bash\ncat > /dev/null; echo x >> %s/calls; cat %s/reply.txt\n' "$d" "$d" > "$d/model"; chmod +x "$d/model"; : > "$d/calls"
export PSM_READ_COMMAND=$d/model
mkdir -p "$d/home/config" "$d/board"
for p in alpha beta gamma; do cp -r "$here/fixture-project" "$d/$p"; done
printf '%s\n' "$d/board/.sign-off/decisions.json" > "$d/home/config/fleet-board"
printf '# projects\n%s opt-in\n%s opt-in\n%s\n' "$d/alpha" "$d/beta" "$d/gamma" > "$d/home/config/project-state-map"
live=1; if command -v sign-off-axi >/dev/null; then (cd "$d/board" && SIGN_OFF_HOME=$d/board sign-off-axi init >/dev/null 2>&1); else
  live=0; printf '#!/usr/bin/env bash\ntrue\n' > "$d/post"; chmod +x "$d/post"; export JG_REPORT_POST=$d/post; echo 'NOTE no sign-off-axi: cards are not posted to a board'; fi

want 'before the first run no project has a card' "$(bash "$refresh" list "$d/home" | grep -c ': card ')" '0'
out=$(bash "$refresh" tick "$d/home")
want 'the first run makes a card for each opted-in project' "$(printf '%s\n' "$out" | grep -c '^refreshed: ') $(wc -l < "$d/calls" | tr -d ' ')" '2 2'
l=$(bash "$refresh" list "$d/home")
want 'the list shows a card per opted-in project' "$(printf '%s\n' "$l" | grep -c '^\(alpha\|beta\): card state-map-')" '2'
want 'the project without the opt-in word is named, not read' "$(printf '%s\n' "$l" | grep '^gamma:')" 'gamma: no card (add the opt-in word to refresh it)'
want 'the cards have different keys' "$(printf '%s\n' "$l" | grep ': card ' | sed 's/.*card //' | sort -u | wc -l | tr -d ' ')" '2'
if [ "$live" = 1 ]; then
  want 'the board holds one live card for each project' "$(jq -r '.items | map(select(.group == "State map" or (.key | startswith("state-map-")))) | length' "$d/board/.sign-off/decisions.json")" '2'
fi
want 'a second run changes nothing and says nothing' "$(bash "$refresh" tick "$d/home" | wc -c | tr -d ' ') $(wc -l < "$d/calls" | tr -d ' ')" '0 2'
rc=0; bash "$refresh" list "$d/nowhere" >/dev/null 2>&1 || rc=$?
want 'a home with no project list is refused' "$rc" '2'
exit "$fail"
