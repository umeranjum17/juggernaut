#!/usr/bin/env bash
# Sealed done-done proof for the project state map (screen: none).
# Runs the search test table, then searches this repository as a real project.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
mkdir -p "$evidence"
t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
{
  echo "== search test table"
  bash "$repo/core/project-state-map/tests/psm-search.test.sh"
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
 "steps":["run the search test table over the fixture project","search this repository and write the hit list"],
 "result":"every table row prints PASS and the real search prints a file count, a hit count and sample hits"}
J
