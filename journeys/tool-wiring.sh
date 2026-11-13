#!/usr/bin/env bash
# done-done journey: drive the real bin/jg-bootstrap.sh install done-done on a clean throwaway HOME, for a
# package that ships integrations/firstmate/ (done-done-axi 0.6.27, the pin) and for one that ships
# integrations/juggernaut/. Only npm is faked: its `root -g` names the package fixture and `install` succeeds.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-tool-wiring}.log
{
  bash "$REPO/tests/jg-tool-wiring.test.sh" || { echo "FAIL: the install is refused" >> "$LOG"; exit 1; }
} >> "$LOG" 2>&1
[ "$(grep -c '^ok - .* layout installs' "$LOG")" = 2 ] || { echo "FAIL: not both layouts installed" >> "$LOG"; exit 1; }
jq -n --arg v "$(git -C "$REPO" rev-parse --short HEAD)" '{target: {version: $v}, start: "a clean HOME with no config and a done-done-axi package on the npm root", steps: ["run bin/jg-bootstrap.sh install done-done against the package layout 0.6.27 ships (integrations/firstmate)", "read the brief include and the merge gate it wrote", "run it again against the integrations/juggernaut layout"], result: "both installs exit 0, the brief include holds the package block and the merge gate is placed executable"}' > "$OUT/steps.json"
