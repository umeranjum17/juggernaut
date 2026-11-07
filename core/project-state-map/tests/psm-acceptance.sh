#!/usr/bin/env bash
# Acceptance chain on the fixture project (report section 11): refresh makes the card, a second run is unchanged with
# no model call, a force run replaces the card, and the card's picture reads at 390 px. Prints each step and fails on a miss.
# Usage: psm-acceptance.sh <evidence-dir>   (needs sign-off-axi and chrome-devtools-axi)
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ev=${1:?psm-acceptance: evidence dir}; mkdir -p "$ev"
a=$(mktemp -d); trap 'rm -rf -- "$a"; timeout 20 chrome-devtools-axi stop >/dev/null 2>&1 || true' EXIT
export CHROME_DEVTOOLS_AXI_SESSION=psm-acceptance-$$
mkdir -p "$a/board" && cp -r "$here/fixture-project" "$a/proj"
(cd "$a/board" && SIGN_OFF_HOME=$a/board sign-off-axi init >/dev/null 2>&1)
board=$a/board/.sign-off/decisions.json
{ echo '```json'; jq -c '{machines, machinery, not_read}' "$here/fixture-map.json"; echo '```'; } > "$a/reply.txt"
printf '#!/usr/bin/env bash\ncat > /dev/null; echo x >> %s/calls; cat %s/reply.txt\n' "$a" "$a" > "$a/model"; chmod +x "$a/model"; : > "$a/calls"
export PSM_READ_COMMAND=$a/model
refresh() { bash "$here/../bin/psm-refresh.sh" run "$a/proj" --state "$a/state" --board "$board" --opt-in "$@"; }
calls() { wc -l < "$a/calls" | tr -d ' '; }
miss() { echo "ACCEPTANCE FAIL: $1"; exit 1; }

echo "== run 1: search, read, prove, draw, post"; refresh; echo "model calls: $(calls)"
[ "$(calls)" = 1 ] || miss 'run 1 should make one model call'
jq -r '"machines kept: \([.machines[].id] | join(", "))", "parts kept: \([.machinery[].id] | join(", "))", "lines dropped and counted: \(.proof.dropped_count)", (.proof.dropped[] | "  dropped \(.where) \(.file):\(.line) \(.reason)")' "$a/state/proved.json"
[ "$(jq -r '[.machines[].id] | sort | join(",")' "$a/state/proved.json")" = gate-state,stuck-flag,ticket-stage ] || miss 'a known machine is missing'
[ "$(jq -r .proof.dropped_count "$a/state/proved.json")" = 7 ] || miss 'the planted false lines were not all counted'
first=$(cat "$a/state/card-key")
echo "== card picture at 390 px"
chrome-devtools-axi open "file://$a/board/.sign-off/state-map/$first/explicit.html" >/dev/null
chrome-devtools-axi resize 390 420 >/dev/null
chrome-devtools-axi eval 'document.body.innerText.replace(/\s+/g, " ")' | tee "$ev/acceptance-card-390.txt"
chrome-devtools-axi screenshot "$ev/acceptance-card-390.png" >/dev/null
grep -q 'queued' "$ev/acceptance-card-390.txt" || miss 'the picture does not show the known states'
echo "== run 2: no change"; out=$(refresh); echo "$out"; echo "model calls: $(calls)"
case "$out" in unchanged:*) ;; *) miss 'run 2 should say unchanged' ;; esac
[ "$(calls)" = 1 ] || miss 'run 2 made a model call'
echo "== run 3: --force"; sleep 1; refresh --force; echo "model calls: $(calls)"
second=$(cat "$a/state/card-key")
[ "$second" != "$first" ] && [ "$(calls)" = 2 ] || miss 'force should make a new card with a new model call'
live=$(jq -r --slurpfile gone <(jq -s '.' "$a/board/.sign-off/decisions.dismissed.jsonl") '[.items[] | select(.key as $k | all($gone[0][]; (.key // .item.key) != $k))] | map(.key) | join(",")' "$board")
echo "live card: $live"
[ "$live" = "$second" ] || miss 'the forced card should be the only live card'
echo "ACCEPTANCE PASS (card, dropped line counted, 390 px picture, unchanged, force)"
