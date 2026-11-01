#!/usr/bin/env bash
# Fleet report card: merges, open PRs, lanes, ready work, stuck workers, captain
# asks and alert quality, built from durable records with no model call.
# Usage: fleet-report.sh <home> [--hours N] [--now <epoch>] [--flow <jg-flow.json>] [--json]
#        fleet-report.sh <home> post [--hours N] [--now <epoch>] [--flow <file>]
#        fleet-report.sh <home> tick [--now <epoch>]
# Reads: jg-flow.v1 (fleet-flow reader, or --flow), data/metrics/task-outcomes.tsv
# (plus files named in JG_REPORT_OUTCOMES), data/metrics/alerts.tsv (see
# fleet-alerts-ledger.sh), config/lane-target. Default text goes to stdout.
# post   Publishes the report as a board report card (key fleet-report-<hours>h-<stamp>),
#        dismissing the previous card of that window
#        with sign-off-axi (or JG_REPORT_POST) on the board named by
#        config/fleet-board.
# tick   For the scheduled check: records alerts, then posts a 4 h card when the
#        last one is 4 h old and a 24 h card when the last one is a day old.
#        Silent unless a post fails.
# False alarm: an alert whose same kind, key stem and subject raised again within
# JG_REPORT_FALSE_SECS (default 600) of the previous one clearing or raising.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
[ "$#" -ge 1 ] || { sed -n 3,6p "$0" | cut -c3- >&2; exit 2; }
home=$(cd "$1" && pwd -P); shift
mode=text; [ "${1:-}" != post ] && [ "${1:-}" != tick ] || { mode=$1; shift; }
hours=24 now=$(date +%s) flow='' json=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hours) hours=${2:?}; shift 2 ;;
    --now) now=${2:?}; shift 2 ;;
    --flow) flow=${2:?}; shift 2 ;;
    --json) json=1; shift ;;
    *) echo "fleet-report: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$hours$now" in *[!0-9]*|'') echo 'fleet-report: --hours and --now need digits' >&2; exit 2 ;; esac

tmps=()
trap 'rm -f -- "${tmps[@]}"' EXIT

build() { # build <hours>
  local h=$1 since f outs=() target='' fl=$flow
  since=$((now - h * 3600))
  if [ -z "$fl" ]; then
    fl=$(mktemp); tmps+=("$fl")
    JG_HOME=$home JG_BIN=${JG_BIN:-$home/bin} bash "${JG_FLOW:-$here/../../fleet-flow/bin/jg-flow.sh}" --json --now "$now" > "$fl" 2>/dev/null || echo '{}' > "$fl"
  fi
  for f in "$home/data/metrics/task-outcomes.tsv" ${JG_REPORT_OUTCOMES:-}; do [ -f "$f" ] && outs+=("$f"); done
  [ -f "$home/config/lane-target" ] && target=$(tr -dc '0-9' < "$home/config/lane-target")
  jq -n --argjson now "$now" --argjson since "$since" --argjson hours "$h" \
    --arg target "$target" --argjson fsecs "${JG_REPORT_FALSE_SECS:-600}" \
    --slurpfile flow "$fl" \
    --rawfile outcomes <( [ "${#outs[@]}" -eq 0 ] || awk -F '\t' 'FNR > 1 && NF >= 8' "${outs[@]}" ) \
    --rawfile alerts <( [ ! -f "$home/data/metrics/alerts.tsv" ] || tail -n +2 "$home/data/metrics/alerts.tsv" ) '
    def rows($t): $t | split("\n") | map(select(length > 0) | split("\t"));
    def med: sort | if length == 0 then null else .[(length / 2 | floor)] end;
    def stem: sub("-[0-9]{9,}$"; "") | sub("^(?<p>squad-lead-[a-z]+(-[a-z]+)*?)-(?<id>.+)$"; "\(.p)");
    ($flow[0] // {}) as $f
    | ($f.lanes // []) as $lanes | ($f.queue // []) as $queue
    | [rows($outcomes)[] | select(.[7] == "merged") | .[8]] as $landed
    | [rows($outcomes)[] | select(.[7] == "merged" and ((.[6] | tonumber? // 0) >= $since))] as $merged
    | [rows($alerts)[] | select((.[0] | tonumber? // 0) >= $since)
        | {raised: (.[0] | tonumber), kind: .[2], key: .[3], cleared: (.[4] | tonumber? // null)}
        | . + {type: (.kind + ":" + (.key | stem)), subject: (.key | sub("-[0-9]{9,}$"; ""))}] as $al
    | ($al | sort_by(.raised)) as $s
    | [range(0; $s | length) as $i | $s[$i] | . as $a
        | (any($s[:$i][]; .type == $a.type and .subject == $a.subject
            and ($a.raised - (.cleared // .raised)) <= $fsecs))] as $rep
    | [range(0; $s | length) | $s[.] + {false_alarm: $rep[.]}] as $alerts
    | [$lanes[] | select(.open and (.stage | IN("blocked","needs-decision","unknown","paused")))
        | {task, home, stage, age: .seconds_in_stage}] as $stuck
    | {hours: $hours, now: $now,
       merges: ($merged | group_by(.[3]) | map({project: .[0][3], merges: length}) | sort_by(-.merges)),
       merges_total: ($merged | length),
       open_prs: ([$lanes[] | select(.open) | (.reason // "") | scan("https://[^ ;,)]+/pull/[0-9]+")] | unique - $landed),
       lanes: {working: ([$lanes[] | select(.open and .stage == "working")] | length),
               target: ($target | if . == "" then null else tonumber end)},
       ready_not_started: ([$queue[] | select(.hold_kind == "-" and (.why | startswith("unknown")))] | length),
       stuck: ($stuck | sort_by(-(.age // 0))
         | map(. + {bucket: (if .age == null then "unknown" elif .age < 3600 then "<1h"
                             elif .age < 14400 then "1-4h" elif .age < 86400 then "4-24h" else ">24h" end)})),
       captain_asks: ([$queue[] | select(.hold_kind == "captain")] | length),
       alerts: {total: ($alerts | length), false_alarms: ($alerts | map(select(.false_alarm)) | length),
                by_type: ($alerts | group_by(.type) | map({type: .[0].type, count: length,
                  false_alarms: (map(select(.false_alarm)) | length),
                  median_clear_secs: (map(select(.cleared != null) | .cleared - .raised) | med),
                  uncleared: (map(select(.cleared == null)) | length)}) | sort_by(-.count))}}'
}

text() { # text <report json on stdin>
  jq -r '
    "Fleet report, last \(.hours) h",
    "Merges: \(.merges_total)" + (if .merges_total > 0 then " (" + (.merges | map("\(.project) \(.merges)") | join(", ")) + ")" else "" end),
    "Open PRs: \(.open_prs | length)" + (if (.open_prs | length) > 0 then " - " + (.open_prs | join(" ")) else "" end),
    "Lanes: \(.lanes.working) working of target \(.lanes.target // "unset")",
    "Ready, not started: \(.ready_not_started)",
    "Stuck workers: \(.stuck | length)" + (if (.stuck | length) > 0 then " - " + (.stuck | map("\(.task) \(.stage) \(.bucket)") | join(", ")) else "" end),
    "Captain asks waiting: \(.captain_asks)",
    "Alerts: \(.alerts.total), false alarms \(.alerts.false_alarms)",
    (.alerts.by_type[] | "  \(.type): \(.count) raised, \(.false_alarms) false, median clear \(.median_clear_secs // "n/a") s, \(.uncleared) uncleared")'
}

post() { # post <hours>
  local h=$1 board json_file card key prev mark=$home/state/.fleet-report-$1h.key
  key=fleet-report-${1}h-$(date -u -d "@$now" +%Y%m%d%H%M)
  board=$(tr -d '\n' < "$home/config/fleet-board" 2>/dev/null || true)
  [ -n "$board" ] || { echo 'fleet-report: config/fleet-board names no board' >&2; return 1; }
  json_file=$(mktemp); card=$(mktemp); tmps+=("$json_file" "$card")
  build "$h" > "$json_file"
  jq --arg key "$key" --arg project "${JG_REPORT_PROJECT:-Fleet}" --arg filed "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" '
    def n($s): [.stuck[] | select(.bucket == $s)] | length;
    {contract: 1, kind: "report", schema: 5, filer: "fleet-report", key: $key, purpose: "status", filed: $filed,
     project: $project, group: "Fleet report",
     title: "\(.merges_total) merges in \(.hours) h; \(.lanes.working) of \(.lanes.target // "?") lanes working",
     about: "\(.ready_not_started) ready items wait and \(.stuck | length) workers are stuck. \(.alerts.false_alarms) of \(.alerts.total) alerts were false alarms.",
     understood: [{label: "You asked", text: "A report card built from durable records, with no model call."},
                  {label: "Done when", text: "Merges, lanes, ready work, stuck workers, captain asks and alert quality are on this card."}],
     visual: {type: "bars", heading: "Merges per project", text: "Merged tasks per project in the window, from the task outcome record.",
              unit: "merges", rows: ((.merges | map({label: .project, value: .merges, note: "merged", tone: "ok"})) as $r | ($r[:7] + (if ($r | length) > 7 then [{label: "other", value: ($r[7:] | map(.value) | add), note: "merged", tone: "ok"}] else [] end)) + [range(0; 2 - ([($r | length), 2] | min)) | {label: "none", value: 0, note: "none", tone: "ok"}]),
              details: [{label: "Open PRs", value: (.open_prs | length | tostring)},
                        {label: "Captain asks waiting", value: (.captain_asks | tostring)},
                        {label: "Stuck over 4 h", value: ([n("4-24h"), n(">24h")] | add | tostring)}]},
     sections: [
       {id: "in-progress", part: "in-progress", stage: "found", heading: "Lanes: \(.lanes.working) working of \(.lanes.target // "?")", body: "\(.ready_not_started) ready items are not started."},
       {id: "blocked", part: "blocked", stage: "found", heading: "Held up: \(.stuck | length) stuck workers", body: (.stuck | map("\(.task) (\(.stage), \(.bucket))") | join(", ") | if . == "" then "None." else . end)},
       {id: "done", part: "done", stage: "found", heading: "Alerts: \(.alerts.total), false \(.alerts.false_alarms)", body: (.alerts.by_type | map("\(.type) \(.count) raised, \(.false_alarms) false") | join("; ") | if . == "" then "None recorded." else . end)},
       {id: "up-next", part: "up-next", stage: "recommend", heading: "Next: tune the noisiest alert", body: "Read the alert lines above and raise the threshold of any type that is mostly false."}],
     next: {heading: "Next report in \(if .hours <= 4 then 4 else 24 end) h", lines: ["The same card refreshes on schedule.", "Open PRs: \(.open_prs | length)."]}}' \
    "$json_file" > "$card"
  ${JG_REPORT_POST:-sign-off-axi} post "$board" --kind report --from "$card" --filer fleet-report
  # One live card per window: dismiss the previous one once the new one is on the board.
  prev=$(cat "$mark" 2>/dev/null || true)
  [ -z "$prev" ] || [ "$prev" = "$key" ] || ${JG_REPORT_POST:-sign-off-axi} dismiss "$board" "$prev" >/dev/null 2>&1 || true
  mkdir -p "$home/state"; printf '%s\n' "$key" > "$mark"
}

case $mode in
  text) if [ "$json" = 1 ]; then build "$hours"; else build "$hours" | text; fi ;;
  post) post "$hours" ;;
  tick)
    bash "$here/fleet-alerts-ledger.sh" "$home" --now "$now"
    mkdir -p "$home/state"
    for pair in 4:14400 24:86400; do
      h=${pair%:*} gap=${pair#*:} mark=$home/state/.fleet-report-${pair%:*}h.last last=0
      [ ! -f "$mark" ] || last=$(cat "$mark")
      [ $((now - last)) -ge "$gap" ] || continue
      if post "$h" >/dev/null; then echo "$now" > "$mark"; else echo "fleet-report: ${h} h card failed to post" >&2; fi
    done ;;
esac
