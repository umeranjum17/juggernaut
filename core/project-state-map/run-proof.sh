#!/usr/bin/env bash
# Sealed done-done proof for the project state map (screen: the three card pictures at 390 px).
# Runs the search, prove, read, card and refresh test tables, the acceptance chain on the fixture project, searches this repository as a real project, proves the fixture map,
# draws its card and captures the three pictures at 390 px.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
mkdir -p "$evidence"
export CHROME_DEVTOOLS_AXI_SESSION=project-state-map-proof-$$
t=$(mktemp -d); trap 'rm -rf -- "$t"; timeout 20 chrome-devtools-axi stop >/dev/null 2>&1 || true' EXIT
{
  echo "== search test table"
  bash "$repo/core/project-state-map/tests/psm-search.test.sh"
  echo "== prove test table"
  bash "$repo/core/project-state-map/tests/psm-prove.test.sh"
  echo "== prove the fixture map (planted false lines)"
  bash "$repo/core/project-state-map/bin/psm-prove.sh" "$repo/core/project-state-map/tests/fixture-map.json" "$repo/core/project-state-map/tests/fixture-project" --out "$evidence/fixture-proved.json"
  jq -r '"kept machines \([.machines[].id] | join(",")) parts \([.machinery[].id] | join(","))", "checked \(.proof.checked) kept \(.proof.kept) dropped \(.proof.dropped_count)", (.proof.dropped[] | "dropped \(.where) \(.file):\(.line) \(.reason)")' "$evidence/fixture-proved.json"
  echo "== read test table"
  bash "$repo/core/project-state-map/tests/psm-read.test.sh"
  echo "== read the fixture hits from a replayed reply, then prove the result"
  bash "$repo/core/project-state-map/bin/psm-search.sh" "$repo/core/project-state-map/tests/fixture-project" --out "$t/fixture-hits.json"
  { echo '```json'; jq -c '{machines, machinery, not_read}' "$repo/core/project-state-map/tests/fixture-map.json"; echo '```'; } > "$t/fixture-reply.txt"
  bash "$repo/core/project-state-map/bin/psm-read.sh" "$t/fixture-hits.json" --replay "$t/fixture-reply.txt" --out "$evidence/fixture-read-replay.json"
  bash "$repo/core/project-state-map/bin/psm-prove.sh" "$evidence/fixture-read-replay.json" "$repo/core/project-state-map/tests/fixture-project" | jq -r '"replayed map: machines \(.machines | length) parts \(.machinery | length) dropped \(.proof.dropped_count)"'
  if [ "${PSM_LIVE_FIXTURE:-0}" = 1 ]; then
    echo "== live read of the fixture project (public fixture code only)"
    bash "$repo/core/project-state-map/bin/psm-read.sh" "$t/fixture-hits.json" --opt-in --out "$evidence/fixture-read-live.json"
    bash "$repo/core/project-state-map/bin/psm-prove.sh" "$evidence/fixture-read-live.json" "$repo/core/project-state-map/tests/fixture-project" | jq -r '"live map: machines \([.machines[].id] | join(",")) parts \([.machinery[].id] | join(",")) checked \(.proof.checked) kept \(.proof.kept) dropped \(.proof.dropped_count)", "read: \(.read | tojson)"'
  fi
  echo "== card test table"
  bash "$repo/core/project-state-map/tests/psm-card.test.sh"
  echo "== draw the card for the fixture map, then capture its pictures at 390 px"
  bash "$repo/core/project-state-map/bin/psm-card.sh" "$evidence/fixture-proved.json" --out-dir "$t/card" --filed 2026-11-07T10:00:00Z
  cp "$t/card/report.json" "$evidence/fixture-card.json"
  jq -r '"card \(.key): \(.title)", (.visual.rows[] | "  \(.label): \(.value)")' "$t/card/report.json"
  for w in explicit hidden machinery; do
    chrome-devtools-axi open "file://$t/card/state-map/$(jq -r .key "$t/card/report.json")/$w.html" >/dev/null
    chrome-devtools-axi resize 390 420 >/dev/null
    chrome-devtools-axi eval 'document.body.innerText.replace(/\s+/g, " ")' >"$evidence/picture-$w-390.txt"
    chrome-devtools-axi screenshot "$evidence/picture-$w-390.png" >/dev/null
    echo "picture $w: $(tr -d '"' < "$evidence/picture-$w-390.txt")"
  done
  echo "== refresh test table"
  bash "$repo/core/project-state-map/tests/psm-refresh.test.sh"
  echo "== acceptance chain on the fixture project: card, unchanged, force"
  bash "$repo/core/project-state-map/tests/psm-acceptance.sh" "$evidence"
  echo "== search a real project (this repository)"
  bash "$repo/core/project-state-map/bin/psm-search.sh" "$repo" --out "$t/real-hits.json"
  jq -r '"files \(.files) hits \(.hits | length) truncated \(.truncated) tree \(.tree)"' "$t/real-hits.json"
  jq '.hits |= .[:20]' "$t/real-hits.json" > "$evidence/real-hits-sample.json"
  jq -r '.hits[:5][] | "\(.file):\(.line) \(.passes | join("+"))"' "$t/real-hits.json"
} 2>&1 | tee "$evidence/project-state-map.txt"
test "${PIPESTATUS[0]}" -eq 0
cat >"$evidence/steps.json" <<'J'
{"target":{"version":"core/project-state-map/bin/psm-search.sh from this checkout"},
 "start":"the fixture project for the table, and this repository as a real project",
 "steps":["run the search, prove, read and card test tables over the fixture project","prove the fixture map and list what was dropped","read the fixture hits from a replayed reply and prove the result","draw the card and capture its three pictures at 390 px","refresh the fixture project twice and with force, checking model calls and the live card","search this repository and write the hit list"],
 "result":"every table row prints PASS, the planted false lines are listed as dropped, and the real search prints a file count, a hit count and sample hits"}
J
