#!/usr/bin/env bash
# Sealed done-done proof for the project state map (screen: none).
# Runs the search and prove test tables, searches this repository as a real project, and proves the fixture map.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
mkdir -p "$evidence"
t=$(mktemp -d); trap 'rm -rf -- "$t"' EXIT
{
  echo "== search test table"
  bash "$repo/core/project-state-map/tests/psm-search.test.sh"
  echo "== prove test table"
  bash "$repo/core/project-state-map/tests/psm-prove.test.sh"
  echo "== prove the fixture map (planted false lines)"
  bash "$repo/core/project-state-map/bin/psm-prove.sh" "$repo/core/project-state-map/tests/fixture-map.json" "$repo/core/project-state-map/tests/fixture-project" --out "$evidence/fixture-proved.json"
  jq -r '"kept machines \([.machines[].id] | join(",")) parts \([.machinery[].id] | join(","))", "checked \(.proof.checked) kept \(.proof.kept) dropped \(.proof.dropped_count)", (.proof.dropped[] | "dropped \(.where) \(.file):\(.line) \(.reason)")' "$evidence/fixture-proved.json"
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
 "steps":["run the search and prove test tables over the fixture project","prove the fixture map and list what was dropped","search this repository and write the hit list"],
 "result":"every table row prints PASS, the planted false lines are listed as dropped, and the real search prints a file count, a hit count and sample hits"}
J
