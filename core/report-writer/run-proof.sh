#!/usr/bin/env bash
# Sealed done-done proof for report-writer (screen: the sitrep page at 390 px).
# Runs the host table, then writes one real sitrep from the live bearings snapshot with the real agy
# and Gemini 4 Neon, lints it, renders it and captures it on a 390 px phone screen.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
home=${JG_MAIN_HOME:-${JG_HOME:-$HOME/juggernaut}}
rw=(python3 -I "$repo/core/report-writer/bin/report-writer.py")
mkdir -p "$evidence"
{
  echo "== host table"
  bash "$repo/core/report-writer/tests/report-writer.test.sh"
  echo "== the live bearings snapshot of $home (the facts)"
  (cd "$home" && bash bin/jg-bearings-snapshot.sh --json) > "$evidence/snapshot.json"
  echo "facts: $(wc -c < "$evidence/snapshot.json") bytes"
  echo "== write the sitrep with the real agy"
  agy --version 2>&1 | head -1 || true
  "${rw[@]}" write sitrep --facts "$evidence/snapshot.json" --out "$evidence/sitrep.md"
  cat "$evidence/sitrep.md"
  echo "== lint it"
  "${rw[@]}" lint sitrep "$evidence/sitrep.md" && echo "lint: clean ($(grep -c . "$evidence/sitrep.md") lines)"
  echo "== render it and capture it at 390 px"
  "${rw[@]}" render "$evidence/sitrep.md" --title "Status report" --out "$evidence/sitrep.html"
  chrome-devtools-axi open "file://$evidence/sitrep.html" >/dev/null
  chrome-devtools-axi resize 390 844 >/dev/null
  chrome-devtools-axi eval 'document.body.innerText.replace(/\s+/g, " ")' | sed -n 's/^result: //p' > "$evidence/sitrep-390.txt"
  chrome-devtools-axi eval 'document.documentElement.scrollWidth' | sed -n 's/^result: //p' | tr -dc '0-9' > "$evidence/sitrep-390-width.txt"
  chrome-devtools-axi screenshot "$evidence/sitrep-390.png" >/dev/null
  echo "page width at a 390 px screen: $(cat "$evidence/sitrep-390-width.txt")"
  test "$(cat "$evidence/sitrep-390-width.txt")" -le 390
  if grep -Eq '(^|[ "(])(/home/|~/|data/|state/)|report\.md' "$evidence/sitrep-390.txt"; then echo "FAIL: a local path shows on the page"; exit 1; fi
  echo "no local path shows on the page"
} 2>&1 | tee "$evidence/report-writer.txt"
test "${PIPESTATUS[0]}" -eq 0
cat > "$evidence/steps.json" <<'J'
{"target":{"version":"core/report-writer from this checkout, with the installed agy"},
 "start":"the live bearings snapshot as the facts, and fixture text for the host table",
 "steps":["run the host table: the model pin, the path scrub, the rewrite, the refusals, the lint rules, the page","write a real sitrep with agy and Gemini 4 Neon from the live snapshot","lint it","render it and capture it at 390 px"],
 "result":"every table row prints PASS, the sitrep is written by Gemini 4 Neon and passes the lint, the page is no wider than 390 px and shows no local path"}
J
