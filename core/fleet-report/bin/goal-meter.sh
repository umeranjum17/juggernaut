#!/usr/bin/env bash
# Goal meter: the numbers of the fleet goal (plan jg-7v6uw, section 11) read from records a home already writes. Read only.
# Usage: goal-meter.sh <home> [--hours N] [--now <epoch>] [--json] [--record]
# Reads:  data/trunk-latency.tsv (minutes and gate seconds of each landing: task head commit first_done ready gate_start launch landed minutes stage gate_secs load),
#         state/chat.jsonl status rows (blocked, needs-decision and failed lines, and the lane's later lines),
#         state/*.meta (kind=scout marks a Recon lane; a lane named fable-* is one too) and data/trunk-landings.tsv.
# A stop from a Recon lane is counted apart, so a Recon's critic wait never hides a worker's stop.
# Leftover: a task record whose commit is already on the trunk. Rows with no record in a home are named under "no record".
# --record appends one row a day to data/metrics/goal-meter.tsv (a second call the same UTC day changes nothing).
set -euo pipefail
[ "$#" -ge 1 ] || { sed -n 2,3p "$0" | cut -c3- >&2; exit 2; }
home=$(cd "$1" && pwd -P); shift
hours=24 now=$(date +%s) json=0 record=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hours) hours=${2:?}; shift 2 ;;
    --now) now=${2:?}; shift 2 ;;
    --json) json=1; shift ;;
    --record) record=1; shift ;;
    *) echo "goal-meter: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$hours$now" in *[!0-9]*|'') echo 'goal-meter: --hours and --now need digits' >&2; exit 2 ;; esac
since=$((now - hours * 3600))
lat=$home/data/trunk-latency.tsv chat=$home/state/chat.jsonl landed=$home/data/trunk-landings.tsv

recon=$(for m in "$home"/state/*.meta; do [ -f "$m" ] || continue
  if grep -q '^kind=scout$' "$m"; then basename "$m" .meta; fi; done | jq -Rn '[inputs]')
left=0
if [ -f "$landed" ]; then
  for m in "$home"/state/*.meta; do [ -f "$m" ] || continue
    if awk -F '\t' -v t="$(basename "$m" .meta)" '$1 == t { f = 1 } END { exit !f }' "$landed"; then left=$((left + 1)); fi
  done
fi

lands=$( [ -f "$lat" ] && awk -F '\t' -v s="$since" -v n="$now" 'NR > 1 && $8 + 0 >= s && $8 + 0 <= n { print $9 "\t" $11 }' "$lat" || true )
stops=$(mktemp); trap 'rm -f -- "$stops"' EXIT
{ [ -f "$chat" ] && jq -R 'fromjson? // empty' "$chat" 2>/dev/null | jq -sc --argjson now "$now" '
  [.[] | select(.kind == "status") | (.text // "") as $t
   | {lane: .from, verb: ($t | split(" ")[0] | split(":")[0] | split("[")[0]),
      at: (($t | capture("\\[at=(?<a>[0-9]+)\\]").a | tonumber?) // .at)}
   | select(.at != null and .at <= $now)] | sort_by(.at)' || echo '[]'; } > "$stops"

rep=$(jq -n --argjson now "$now" --argjson since "$since" --argjson hours "$hours" --argjson recon "$recon" \
  --slurpfile stopsf "$stops" --argjson left "$left" --rawfile lands <(printf '%s\n' "$lands") '
  def isrecon: . as $l | ($recon | index($l) != null) or ($l | tostring | startswith("fable-"));
  def p90: sort | if length == 0 then null else .[((length - 1) * 0.9 | floor)] end;
  ($stopsf[0] // []) as $stops
  | ($lands | split("\n") | map(select(length > 0) | split("\t"))) as $L
  | [$L[] | select(.[0] != "") | .[0] | tonumber] as $mins
  | [$L[] | select(.[1] != "" and .[1] != null) | .[1] | tonumber] as $gates
  | [$stops[] | select(.at >= $since and (.verb | IN("blocked", "needs-decision", "failed")))] as $asks
  | def closing($a): [$stops[] | select(.lane == $a.lane and .at > $a.at)];
    def outcome($a): (closing($a)) as $n
      | ($n | map(select(.verb == "resolved")) | first // null) as $r
      | if $r then {k: "resolved", s: ($r.at - $a.at)} elif ($n | length) > 0 then {k: "moved"} else {k: "open"} end;
    ([$asks[] | select(.lane | isrecon | not)]) as $w | ([$asks[] | select(.lane | isrecon)]) as $r
    | ($w | map(outcome(.))) as $wo
    | {hours: $hours, now: $now,
       landings: {count: ($mins | length), no_done_line: (($L | length) - ($mins | length)), within_5_min: ([$mins[] | select(. <= 5)] | length),
                  pct_within_5: (if ($mins | length) == 0 then null else (([$mins[] | select(. <= 5)] | length) * 100 / ($mins | length) | round) end),
                  pass: (($mins | length) >= 20 and (([$mins[] | select(. <= 5)] | length) * 100 / ($mins | length)) >= 90)},
       gate_p90_secs: ($gates | p90),
       stops: {count: ($w | length), answered_in_300_s: ([$wo[] | select(.k == "resolved" and .s <= 300)] | length),
               resolved: ([$wo[] | select(.k == "resolved")] | length), median_answer_secs: ([$wo[] | select(.k == "resolved") | .s] | sort | if length == 0 then null else .[(length / 2 | floor)] end),
               never_closed: ([$wo[] | select(.k != "resolved")] | length), open: ([$wo[] | select(.k == "open")] | length),
               recon_lines: ($r | length), recon_lanes: ($r | map(.lane) | unique | length)},
       leftover_records: $left,
       no_record: ["minutes main is behind the green pin", "landings refused by a time budget", "lead turns per landing", "wakes with no step", "model-guard alarms", "panes with no record", "stale text in an input box", "pull requests with no owner", "status files with no record", "owner answers not applied"]}')

if [ "$record" = 1 ]; then
  day=$(date -u -d "@$now" +%Y-%m-%d) f=$home/data/metrics/goal-meter.tsv
  mkdir -p "$home/data/metrics"
  [ -f "$f" ] || printf 'day\thours\tlandings\tpct_within_5\tgate_p90_secs\tstops\tanswered_in_300_s\tnever_closed\trecon_lines\tleftovers\n' > "$f"
  cut -f1 "$f" | grep -qx "$day" || jq -r --arg d "$day" '[$d, .hours, .landings.count, (.landings.pct_within_5 // "-"), (.gate_p90_secs // "-"),
    .stops.count, .stops.answered_in_300_s, .stops.never_closed, .stops.recon_lines, .leftover_records] | @tsv' <<<"$rep" >> "$f"
fi
if [ "$json" = 1 ]; then printf '%s\n' "$rep"; else
  jq -r '"Goal meter, last \(.hours) h",
    "Landings inside 5 min: \(.landings.within_5_min) of \(.landings.count)" + (if .landings.pct_within_5 != null then " (\(.landings.pct_within_5)%)" else "" end) + " - pass needs 90% of 20 or more: \(if .landings.pass then "met" else "not met" end)",
    "Gate p90: \(.gate_p90_secs // "n/a") s (goal under 300)",
    "Stops (Recon apart): \(.stops.count); answered inside 300 s \(.stops.answered_in_300_s); resolved \(.stops.resolved), median \(.stops.median_answer_secs // "n/a") s; never closed \(.stops.never_closed)",
    "Recon lines: \(.stops.recon_lines) from \(.stops.recon_lanes) lanes",
    "Leftover records: \(.leftover_records)",
    "No record in a home: \(.no_record | join("; "))"' <<<"$rep"
fi
