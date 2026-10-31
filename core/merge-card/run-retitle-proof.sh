#!/usr/bin/env bash
# Seed an isolated sign-off board and drive the retitle command through sign-off-axi.
set -euo pipefail

: "${DONE_DONE_EVIDENCE_ROOT:?done-done must provide its run evidence folder}"
command -v sign-off-axi >/dev/null || { echo 'sign-off-axi is required' >&2; exit 1; }
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }
fixture=$DONE_DONE_EVIDENCE_ROOT/retitle-board
mkdir -p "$fixture/.sign-off" "$fixture/bin"
(
  cd "$fixture"
  SIGN_OFF_HOME="$fixture/.sign-off" sign-off-axi init >/dev/null
)
# The forge's own title for the seeded PR: the replacement title comes from it, never invented here.
printf '#!/usr/bin/env bash\ncase " $* " in *" --jq .title "*) echo "Seed the retitle journey"; exit 0 ;; esac\nexit 1\n' >"$fixture/bin/gh"
chmod +x "$fixture/bin/gh"
board=$fixture/.sign-off/decisions.json
message=$fixture/legacy-card.json
jq -n '{contract:1,kind:"evidence",schema:1,key:"merge-acme-retitle-demo-pull-17",title:"retitle-demo #17: internal change passed its checks",about:"Seeded legacy card",link:"https://github.com/acme/retitle-demo/pull/17",run:{run_id:"20261023T000000Z-retitle01",commit:"0123456789012345678901234567890123456789",outcome:"The fixture title changes",repro:"Run the fixture journey",proof:"done-done run merge-card-retitle",evidence:"seeded fixture"}}' >"$message"
sign-off-axi post "$board" --kind evidence --from "$message" --filer juggernaut-merge >/dev/null

dry=$(PATH="$fixture/bin:$PATH" bash "$(dirname "$0")/retitle-old-cards" "$board")
[[ "$dry" == *'retitle-demo #17: internal change passed its checks -> Seed the retitle journey'* ]]
[[ $(sign-off-axi list "$board" --json --full | jq '[.decisions[] | select(.title == "retitle-demo #17: internal change passed its checks" and .dismissed != true)] | length') == 1 ]]

applied=$(PATH="$fixture/bin:$PATH" bash "$(dirname "$0")/retitle-old-cards" --apply "$board")
[[ "$applied" == *'retitled 1 card(s); skipped 0'* ]]
sign-off-axi list "$board" --json --full | jq -e '
  ([.decisions[] | select(.title == "retitle-demo #17: internal change passed its checks" and .dismissed == true)] | length) == 1
  and ([.decisions[] | select(.title == "Seed the retitle journey" and .dismissed != true and .evidence.run_id == "20261023T000000Z-retitle01")] | length) == 1
' >/dev/null

again=$(PATH="$fixture/bin:$PATH" bash "$(dirname "$0")/retitle-old-cards" --apply "$board")
[[ "$again" == *'retitled 0 card(s); skipped 0'* ]]
jq -n --arg version "$(sign-off-axi --version | head -n 1)" \
  '{target:{version:$version},start:"A seeded sign-off board has one legacy generic evidence card.",steps:["Create an isolated board with sign-off-axi and seed a generic card whose pull request has a readable title.","Run the retitle command without --apply and confirm it previews the card with the outcome sentence it read.","Run with --apply and inspect the active and archived cards through sign-off-axi.","Run with --apply again and confirm no new card is added."],result:"The active evidence card is titled with its pull request own outcome sentence, its proof record and link remain attached, and the second apply changes nothing."}' >"$DONE_DONE_EVIDENCE_ROOT/steps.json"
printf '%s\n' 'real sign-off-axi retitle journey passed'
