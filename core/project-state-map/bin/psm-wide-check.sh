#!/usr/bin/env bash
# Project state map, the wide-report rule: a report that touches many parts of a project must carry the project's map.
# Usage: psm-wide-check.sh <report.md> --project <name> --state <dir> [--config <dir>] [--min N]
# Counts how many of the project's proved machines and parts the report names, from the map the refresh stored in
# <state>/project-state-map/<name>/proved.json. A machine or part counts once when its name or id (words, any case) is in the
# text. At --min (default 3) or more the report is wide and must carry the map: the id of the project's card (state-map-<name>-...)
# or a heading named State map. No model call; the check only compares the report text with the stored map.
# Output: PASS (narrow, or wide and with the map), SKIP (no map stored for the project), WARN (wide, no map, still in the warn
# period), REFUSED (wide, no map, rule in force). Exit 0 for PASS, SKIP and WARN, 1 for REFUSED, 2 for bad input.
# Warn period: the first check writes <state>/project-state-map/wide-since; the rule refuses 7 days after that. A line "warn"
# in <config>/project-state-map-wide keeps the rule at warn only. PSM_NOW (epoch) overrides the clock for tests.
set -euo pipefail

report='' project='' state='' config='' min=3
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) project=${2:?}; shift 2 ;;
    --state) state=${2:?}; shift 2 ;;
    --config) config=${2:?}; shift 2 ;;
    --min) min=${2:?}; shift 2 ;;
    -h|--help) sed -n 2,13p "$0" | cut -c3-; exit 0 ;;
    -*) echo "psm-wide-check: unknown argument $1" >&2; exit 2 ;;
    *) [ -z "$report" ] || { echo 'psm-wide-check: one report only' >&2; exit 2; }; report=$1; shift ;;
  esac
done
[ -n "$report" ] && [ -n "$project" ] && [ -n "$state" ] || { sed -n 2,3p "$0" | cut -c3- >&2; exit 2; }
[ -f "$report" ] || { echo "psm-wide-check: no report at $report" >&2; exit 2; }
case "$min" in ''|*[!0-9]*) echo 'psm-wide-check: --min needs digits' >&2; exit 2 ;; esac
command -v jq >/dev/null || { echo 'psm-wide-check: needs jq' >&2; exit 2; }

proved=$state/project-state-map/$project/proved.json
if [ ! -s "$proved" ]; then echo "SKIP: no state map is stored for $project, so there is nothing to count."; exit 0; fi

norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ' | tr -s ' ' | sed -e 's/^/ /' -e 's/$/ /'; }
text=$(norm "$(cat "$report")")
named=''; n=0
while IFS=$'\t' read -r id name; do
  for w in "$name" "$id"; do
    nw=$(norm "$w")
    if [ "${#nw}" -ge 7 ] && [ "${text#*"$nw"}" != "$text" ]; then named="$named${named:+, }$name"; n=$((n + 1)); break; fi
  done
done < <(jq -r '(.machines + .machinery)[] | [.id, .name] | @tsv' "$proved")

if [ "$n" -lt "$min" ]; then echo "PASS: the report names $n of the project's states and parts, so it is narrow."; exit 0; fi
if grep -qiE "state-map-$project-|^#+[[:space:]]+([0-9]+[.)]?[[:space:]]+)?state map" "$report"; then
  echo "PASS: the report names $n states and parts ($named) and carries the project's state map."; exit 0
fi
card=$(cat "$state/project-state-map/$project/card-key" 2>/dev/null || true)
msg="the report names $n states and parts ($named) and does not carry the state map of $project. Add the map card${card:+ ($card)} or a State map section."
now=${PSM_NOW:-$(date +%s)}; since_file=$state/project-state-map/wide-since
[ -s "$since_file" ] || { printf '%s\n' "$now" > "$since_file.new" && mv "$since_file.new" "$since_file"; }
since=$(cat "$since_file")
warnonly=0; [ -z "$config" ] || [ ! -f "$config/project-state-map-wide" ] || [ "$(tr -d ' \n' < "$config/project-state-map-wide")" != warn ] || warnonly=1
if [ "$warnonly" = 1 ] || [ $((now - since)) -lt 604800 ]; then
  echo "WARN: $msg The rule becomes a refusal after its first week." >&2; exit 0
fi
echo "REFUSED: $msg" >&2; exit 1
