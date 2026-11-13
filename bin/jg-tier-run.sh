#!/usr/bin/env bash
# jg-tier-run.sh <tier> - run every journey of .done-done.yaml marked `tier: <tier>`, one `done-done run <journey> --tier <tier>`
# each. done-done-axi 0.6.27 takes --tier only as a filter on a named journey: `done-done run --tier ci` alone stops with
# "run needs a journey" (exit 2), so the tier runner names each journey. Every journey runs; the exit is 1 if any was red,
# 2 if the tier holds no journey (an empty tier must never pass).
set -u
tier="${1:-}"
[ -n "$tier" ] || { echo "usage: jg-tier-run.sh <tier>" >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="${JG_TIER_CONFIG:-$ROOT/.done-done.yaml}"
journeys="$(awk -v want="$tier" '
  /^journeys:/ {inj=1; next}
  /^[^ #]/ {if (inj) flush(); inj=0}
  inj && /^  [A-Za-z0-9_-]+:$/ {flush(); name=$1; sub(/:$/,"",name); tier=""; next}
  inj && /^    tier: / {tier=$2; next}
  function flush() {if (name!="" && tier==want) print name; name=""}
  END {flush()}' "$CFG")"
[ -n "$journeys" ] || { echo "jg-tier-run: no journey with tier $tier in $CFG" >&2; exit 2; }
red=0
n=0
while IFS= read -r j; do
  n=$((n + 1))
  echo "== $j"
  (cd "$ROOT" && done-done run "$j" --tier "$tier") || { echo "jg-tier-run: $j is red" >&2; red=$((red + 1)); }
done <<<"$journeys"
echo "jg-tier-run: $n journeys in tier $tier, $red red"
[ "$red" = 0 ]
