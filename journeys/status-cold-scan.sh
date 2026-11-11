#!/usr/bin/env bash
# Drive the real captured-status reader with a cold 20,000-line history.
set -eu
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
lab=$(mktemp -d "${TMPDIR:-/tmp}/jg-status-cold-scan.XXXXXX")
trap 'rm -rf -- "$lab"' EXIT
# shellcheck source=bin/jg-classify-lib.sh
. "$root/bin/jg-classify-lib.sh"
printf 'kind=ship\n' > "$lab/task.meta"
awk 'BEGIN {for(i=1;i<=20000;i++) print "working: history " i; print "blocked [key=access]: waiting"}' > "$lab/task.status"
cp "$lab/task.status" "$lab/before"
record=''; needs=0
{ time status_span_first_actionable_record "$lab/task.status" 0 record needs; } 2> "$evidence/timing.log"
printf '%s\n' "$record" > "$evidence/cold-span.txt"
[ "${record#*$'\t'*$'\t'}" = 'blocked [key=access]: waiting' ]
[ "$needs" -eq 0 ]
cmp "$lab/before" "$lab/task.status"
[ -z "$(find "$lab" -name '*cursor*' -print)" ]
printf 'The cold span returned its blocker and endpoint; all source bytes remain unchanged and no cursor was advanced.\n' > "$evidence/result.log"
cat > "$evidence/steps.json" <<JSON
{"target":{"version":"$(git -C "$root" rev-parse HEAD)"},
 "start":"A cold reader has 20000 historical progress lines followed by a live blocker.",
 "steps":["Classify the captured span through the real shared status reader.","Check the returned blocker and endpoint.","Compare every source byte and check that no cursor was advanced."],
 "result":"The complete cold span is classified with its live blocker retained and no history or presentation state changed."}
JSON
cat "$evidence/result.log" "$evidence/timing.log"
