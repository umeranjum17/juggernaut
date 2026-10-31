#!/usr/bin/env bash
# done-done journey: run the real core/model-gate/bin/jg-model-gate six times at once against a throwaway
# opencode.json and write the before/after config, run log and leftovers into the evidence folder.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/config" "$T/oc"
echo '{"deepseek":["m1"]}' >"$T/home/config/model-allow-list.json"
echo '{"provider":{"deepseek":{"models":{"m1":{}}}},"plugin":["keep-me"]}' >"$T/oc/opencode.json"
cp "$T/oc/opencode.json" "$OUT/before.json"
export HOME=$T/home JG_HOME=$T/home OPENCODE_CONFIG=$T/oc/opencode.json
for i in 1 2 3 4 5 6; do ( "$REPO/core/model-gate/bin/jg-model-gate" opencode >>"$OUT/runs.log" 2>&1; echo "run $i exit $?" >>"$T/exits" ) & done
wait
cp "$T/oc/opencode.json" "$OUT/after.json"
{ echo "concurrent runs started together: 6; finished: $(wc -l <"$T/exits"); exited 0: $(grep -c 'exit 0$' "$T/exits")"; echo "bytes: $(wc -c <"$T/oc/opencode.json")"; jq -c . "$T/oc/opencode.json"; echo "leftover lock/tmp files: $(find "$T/oc" \( -name '*.lock' -o -name '*.tmp.*' \) | wc -l)"; } | tee "$OUT/result.txt"
jq -n --arg v "$(git -C "$REPO" rev-parse --short HEAD)" --arg r "$(jq -c . "$T/oc/opencode.json")" '{target: {version: $v}, start: "an opencode.json with a deepseek provider and no whitelist, and an allow-list naming m1", steps: ["start six jg-model-gate opencode runs at the same moment", "wait for all six to finish"], result: ("opencode.json is valid JSON with the whitelist set: " + $r)}' >"$OUT/steps.json"
jq -e '.provider.deepseek.whitelist == ["m1"] and .plugin == ["keep-me"]' "$T/oc/opencode.json" >/dev/null &&
  [ "$(find "$T/oc" \( -name '*.lock' -o -name '*.tmp.*' \) | wc -l)" -eq 0 ]
