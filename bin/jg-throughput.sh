#!/usr/bin/env bash
# jg-throughput.sh - the throughput choke-point measurement as code: where the
# hours go between a worker's done line and a merged pull request, ranked by
# hours lost so the worst bottleneck is the first thing a reader sees.
#
# WHY THIS EXISTS (migration step 5i). A one-off report measured 162 merged pull
# requests and found 458 PR-hours between done and merged in seven days; the
# method lived in discarded scratch scripts, so nobody could re-measure it. This
# tool is that method, with every threshold and every proposed fix in config, so
# the number is reviewable and the ranking is reproducible.
#
# CONTRACT (this header is the one owner of the measurement's shape).
#   inputs      A home's own records when no directory is named: the fleet ledger
#               (state/fleet-ledger.jsonl), the per-task outcomes
#               (data/metrics/task-outcomes.tsv) and the two forge dumps `fetch`
#               writes. `--inputs <dir>` reads a lab's fixtures by the same names:
#               ledger.jsonl, task-outcomes.tsv, prs.json, runs.json.
#   fetch       Writes the two forge dumps once, from the pull requests merged in
#               the window and the workflow runs whose head is one of their final
#               commits. Nothing else reaches the forge, so a re-measure over the
#               same dumps is free and repeatable.
#   measure     One record per merged pull request: its done line, its final
#               commit, the moment its checks went green, and its merge. Every
#               second between done and merged is attributed to exactly one stage,
#               so the stages sum to the whole wait.
#   stages      rework (done -> final commit), queue (runner wait inside the final
#               CI), run (CI runtime inside it), green_to_merged (last green check
#               -> merge), handoff (whatever no record was running for). The
#               stage ids and every proposed fix are configuration.
#   rank        Hours and hours per day per stage over the window, with the median
#               and p90 per pull request, ranked by hours per day. A stage below
#               min-hours-per-day is measured and not ranked: a rounding error
#               never becomes a ticket.
#   window      The last window-days days, ending at the newest merged record the
#               inputs hold, so a replayed dump always measures the same window.
#
# Usage:
#   jg-throughput.sh fetch [--since <YYYY-MM-DD>]
#   jg-throughput.sh measure [--inputs <dir>] [--at <epoch>]
#   jg-throughput.sh rank [--inputs <dir>] [--json]
#   jg-throughput.sh show [--inputs <dir>]
#
# Environment: JG_HOME, JG_ROOT_OVERRIDE, JG_STATE_OVERRIDE, JG_CONFIG_OVERRIDE,
# JG_THROUGHPUT (the definition), JG_THROUGHPUT_NOW (a pinned clock).
set -u
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
CONFIG=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
OUT=$STATE/.throughput

die() { printf 'jg-throughput: %s\n' "$*" >&2; exit 2; }

definition() {
  local f
  for f in "${JG_THROUGHPUT:-}" "$CONFIG/throughput.json" "$ROOT/defaults/throughput.json"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    printf '%s' "$f"
    return 0
  done
  return 1
}

wf() { jq -er "$1" "$DEF"; }  # one field of the definition in force

# The four inputs, from a labelled directory or from this home's own records.
inputs_dir() {
  if [ -n "${INPUTS:-}" ]; then
    [ -d "$INPUTS" ] || die "no input directory at $INPUTS"
    printf '%s' "$INPUTS"
    return 0
  fi
  mkdir -p "$OUT/inputs" 2>/dev/null || die "cannot create $OUT/inputs"
  printf '%s' "$OUT/inputs"
}

input_path() {  # <name>
  local dir name=$1
  dir=$(inputs_dir) || exit 1
  if [ -n "${INPUTS:-}" ]; then
    printf '%s/%s' "$dir" "$name"
    return 0
  fi
  case "$name" in
    ledger.jsonl)
      printf '%s' "${LEDGER:-$STATE/fleet-ledger.jsonl}" ;;
    task-outcomes.tsv)
      printf '%s' "${OUTCOMES:-$DATA/metrics/task-outcomes.tsv}" ;;
    *)
      printf '%s/%s' "$dir" "$name" ;;
  esac
}

# --- fetch ------------------------------------------------------------------
# Two forge dumps: the merged pull requests of the window with their commits, and
# the workflow runs on their final commits with their jobs. One read each, so the
# measurement itself never talks to GitHub.
cmd_fetch() {
  local since='' day run
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --since) since=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  command -v gh >/dev/null 2>&1 || die 'gh is required to fetch the forge data'
  day=${since:-$(date -u -d "@$(( ${JG_THROUGHPUT_NOW:-$(date +%s)} - $(wf '.["window-days"]') * 86400 ))" +%Y-%m-%d 2>/dev/null)}
  [ -n "$day" ] || die 'could not resolve the window start; pass --since'
  mkdir -p "$OUT/inputs" || die "cannot create $OUT/inputs"
  : >"$OUT/inputs/prs.json.tmp" || return 1
  local repo
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    gh pr list --repo "$repo" --state merged --limit 200 \
      --search "merged:>=$day" \
      --json number,url,mergedAt,commits,baseRefName 2>/dev/null \
      | jq -c --arg repo "$repo" '.[] | . + {repo: $repo}' >>"$OUT/inputs/prs.json.tmp" || true
  done <<EOF
$(wf '.repos[]?')
EOF
  jq -s -c '.' "$OUT/inputs/prs.json.tmp" >"$OUT/inputs/prs.json" || return 1
  rm -f "$OUT/inputs/prs.json.tmp"
  # Runs on the final commit of each pull request, with their jobs.
  : >"$OUT/inputs/runs.json.tmp" || return 1
  local sha jobs
  while IFS=$'\t' read -r repo sha; do
    [ -n "$sha" ] || continue
    run=$(gh api "repos/$repo/actions/runs?head_sha=$sha&per_page=10" \
      --jq '[.workflow_runs[] | {id, head_sha, status, conclusion, created_at, run_started_at, updated_at}]' 2>/dev/null) || continue
    printf '%s' "$run" | jq -c --arg repo "$repo" '.[] | . + {repo: $repo}' 2>/dev/null >>"$OUT/inputs/runs.json.tmp" || true
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      jobs=$(gh api "repos/$repo/actions/runs/$id/jobs?filter=all&per_page=100" \
        --jq '[.jobs[] | {created_at, started_at, completed_at, conclusion}]' 2>/dev/null) || continue
      printf '%s' "$jobs" | jq -c --argjson id "$id" --arg repo "$repo" '{id: $id, repo: $repo, jobs: .}' \
        >>"$OUT/inputs/jobs.json.tmp" || true
    done <<EOF2
$(printf '%s' "$run" | jq -r '.[].id' 2>/dev/null)
EOF2
  done <<EOF
$(jq -r '.[] | [.repo, (.commits[-1].oid // "")] | @tsv' "$OUT/inputs/prs.json" 2>/dev/null)
EOF
  jq -s -c '.' "$OUT/inputs/runs.json.tmp" >"$OUT/inputs/runs.json" 2>/dev/null || printf '[]\n' >"$OUT/inputs/runs.json"
  jq -s -c '.' "$OUT/inputs/jobs.json.tmp" >"$OUT/inputs/jobs.json" 2>/dev/null || printf '[]\n' >"$OUT/inputs/jobs.json"
  rm -f "$OUT/inputs/runs.json.tmp" "$OUT/inputs/jobs.json.tmp"
  printf 'fetched: %s pull request(s), %s run(s) into %s\n' \
    "$(jq -r 'length' "$OUT/inputs/prs.json" 2>/dev/null)" \
    "$(jq -r 'length' "$OUT/inputs/runs.json" 2>/dev/null)" "$OUT/inputs"
}

# --- measure ----------------------------------------------------------------
# One record per merged pull request. The ledger carries the done line and the
# merge as events; the forge dumps carry the commits and the runs.

iso_epoch() {  # <iso8601> -> epoch or empty
  local t=${1:-}
  [ -n "$t" ] || return 0
  jq -r --arg t "$t" 'try ($t | fromdateiso8601) catch empty' <<<'null' 2>/dev/null
}

done_epoch_from_text() {  # <status text> -> the at= stamp, else empty
  printf '%s' "${1:-}" | sed -n 's/.*\[at=\([0-9][0-9]*\)\].*/\1/p' | head -1
}

cmd_measure() {
  local ledger prs runs jobs outcomes from to window days
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --inputs) INPUTS=$2; shift 2 ;;
      --at) JG_THROUGHPUT_NOW=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  mkdir -p "$OUT" 2>/dev/null || die "cannot create $OUT"
  ledger=$(input_path ledger.jsonl)
  prs=$(input_path prs.json)
  runs=$(input_path runs.json)
  jobs=$(input_path jobs.json)
  outcomes=$(input_path task-outcomes.tsv)
  [ -f "$prs" ] || die "no pull-request dump at $prs (run fetch, or pass --inputs)"
  [ -f "$ledger" ] || : >"$ledger"
  [ -f "$runs" ] || printf '[]\n' >"$runs"
  [ -f "$jobs" ] || printf '[]\n' >"$jobs"
  [ -f "$outcomes" ] || : >"$outcomes"

  # The window ends at the newest merge the dumps hold, so a replayed dump
  # measures the same window whatever today is.
  to=$(jq -r '[.[].mergedAt | fromdateiso8601] | max // empty' "$prs" 2>/dev/null) || to=
  case "$to" in '' | *[!0-9]*) to=${JG_THROUGHPUT_NOW:-$(date +%s)} ;; esac
  days=$(wf '.["window-days"]')
  window=$(( days * 86400 ))
  from=$(( to - window ))

  jq -c --argjson from "$from" --argjson to "$to" '
    [.[] | select(.mergedAt != null)
         | select((.mergedAt | fromdateiso8601) >= $from)
         | select((.mergedAt | fromdateiso8601) <= $to)]
  ' "$prs" >"$OUT/window-prs.json" 2>/dev/null || printf '[]\n' >"$OUT/window-prs.json"

  local record skipped=0
  : >"$OUT/merges.jsonl"
  : >"$OUT/skipped.jsonl"
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    measure_one "$record" "$ledger" "$runs" "$jobs" >>"$OUT/merges.jsonl" 2>/dev/null || {
      printf '%s\n' "$record" >>"$OUT/skipped.jsonl"
      skipped=$(( skipped + 1 ))
    }
  done <<EOF
$(jq -c '.[]' "$OUT/window-prs.json" 2>/dev/null)
EOF

  local n_merges n_skipped
  n_merges=$(wc -l <"$OUT/merges.jsonl" | tr -d ' ')
  n_skipped=$(wc -l <"$OUT/skipped.jsonl" | tr -d ' ')
  jq -s -c --argjson from "$from" --argjson to "$to" --argjson days "$days" \
    --argjson measured "$n_merges" --argjson skipped "$n_skipped" '
    { schema: "jg-throughput.v1",
      window: {from: $from, to: $to, days: $days},
      measured: $measured, skipped: $skipped,
      merges: . }' "$OUT/merges.jsonl" >"$OUT/dataset.json" || return 1
  printf '%s\n' "$OUT/dataset.json"
}

# forge_timings <pr-record> <runs> <jobs>
# Prints "<green_at>\t<queue_s>\t<run_s>" for the runs on the pull request's
# final commit, or nothing when no successful run is recorded there. The queue is
# each job's wait between being created and starting, the run time is each job's
# own runtime, and both are summed over the final commit's runs only.
forge_timings() {
  local pr=$1 runs=$2 jobs=$3 repo sha
  repo=$(printf '%s' "$pr" | jq -r '.repo')
  sha=$(printf '%s' "$pr" | jq -r '.commits[-1].oid // ""')
  [ -n "$sha" ] || return 0
  jq -r --slurpfile r "$runs" --arg repo "$repo" --arg sha "$sha" '
    [ $r[0][] | select(.repo == $repo and .head_sha == $sha and .conclusion == "success") | .id ] as $ids
    | [ .[] | select(.id as $i | $ids | index($i)) | .jobs[]
        | select(.started_at != null) ] as $jobs
    | if ($jobs | length) == 0 then empty
      else
        ($jobs | map(.completed_at | select(. != null) | fromdateiso8601) | if length == 0 then 0 else max end) as $green
        | ($jobs | map((.started_at | fromdateiso8601) - (.created_at | fromdateiso8601)) | add // 0) as $queue
        | ($jobs | map(select(.completed_at != null) | (.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601)) | add // 0) as $run
        | "\($green)\t\($queue)\t\($run)"
      end' "$jobs" 2>/dev/null | head -1
}

# measure_one <pr-record> <ledger> <runs> <jobs>
# Prints one record; exits non-zero when the pull request has no done line, which
# is the one thing the local records may not hold.
measure_one() {
  local pr=$1 ledger=$2 runs=$3 jobs=$4
  local url task done_at last_commit merged_at timings green_at queue_s run_s
  url=$(printf '%s' "$pr" | jq -r '.url')
  task=$(jq -r --arg u "$url" '
    select(.event != null) | select((.pr // "") == $u) | .task' "$ledger" 2>/dev/null | head -1) || task=
  done_at=$(jq -r --arg u "$url" '
    select(.event == "task.status")
    | select((.text // "") | test("^done [\\[:]"))
    | select((.pr // "") == $u or (.pr // "") == "")
    | (.text | capture("at=(?<at>[0-9]+)").at) // .ts' "$ledger" 2>/dev/null | head -1) || done_at=
  case "$done_at" in '' | *[!0-9]*) return 1 ;; esac
  last_commit=$(printf '%s' "$pr" | jq -r '[.commits[].committedDate | fromdateiso8601] | max // empty')
  case "$last_commit" in '' | *[!0-9]*) last_commit=$done_at ;; esac
  merged_at=$(printf '%s' "$pr" | jq -r '.mergedAt | fromdateiso8601')
  case "$merged_at" in '' | *[!0-9]*) return 1 ;; esac
  timings=$(forge_timings "$pr" "$runs" "$jobs") || timings=
  green_at=${timings%%"${timings#*	}"}
  queue_s=0
  run_s=0
  if [ -n "$timings" ]; then
    IFS=$'\t' read -r green_at queue_s run_s <<<"$timings"
    case "$green_at" in '' | *[!0-9]*) green_at=0 ;; esac
    case "$queue_s" in '' | *[!0-9]*) queue_s=0 ;; esac
    case "$run_s" in '' | *[!0-9]*) run_s=0 ;; esac
  else
    green_at=0
  fi
  printf '%s' "$pr" | jq -c \
    --argjson donets "$done_at" --argjson lastc "$last_commit" \
    --argjson green "$green_at" --argjson merged "$merged_at" \
    --argjson queue "$queue_s" --argjson run "$run_s" \
    --arg task "${task:-}" '
    def clamp(x; lo; hi): if x < lo then lo elif x > hi then hi else x end;
    def secs(a; b): if b <= a then 0 else b - a end;
    . as $p
    | ($green | if . == 0 then null else . end) as $g
    | ($donets) as $a
    | ($merged) as $d
    | (clamp($lastc; $a; $d)) as $b
    | (if $g == null then $b else clamp($g; $b; $d) end) as $c
    | { home: null, task: $task, repo: $p.repo, url: $p.url, pr: $p.number,
        done_at: $a, last_commit_at: $lastc, green_at: $g, merged_at: $d,
        rework_s: secs($a; $b),
        final_ci_s: secs($b; $c),
        queue_s: (if $g == null then 0 else $queue end),
        run_s: (if $g == null then 0 else $run end),
        green_to_merged_s: (if $g == null then 0 else secs($c; $d) end),
        total_s: secs($a; $d) }
    | .handoff_s = ([.total_s - .rework_s - .final_ci_s - .green_to_merged_s, 0] | max)'
}

# --- rank -------------------------------------------------------------------
# Hours per stage over the window, ranked by hours per day.
cmd_rank() {
  local json=0 WIN_DAYS=7
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --inputs) INPUTS=$2; shift 2 ;;
      --json) json=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -f "$OUT/dataset.json" ] || cmd_measure >/dev/null || die 'no measurement to rank'
  WIN_DAYS=$(jq -r '.window.days' "$OUT/dataset.json") || WIN_DAYS=7
  local stage_rows
  stage_rows=$(jq -r '
    .merges as $m
    | ["rework", "queue", "run", "green_to_merged", "handoff"] as $stages
    | $stages[] as $s
    | ($s + "_s") as $field
    | [ $m[] | .[$field] // 0 ] as $v
    | select(($v | add // 0) > 0)
    | [ $s, ($v | add // 0), ($v | map(select(. > 0)) | length),
        ($v | sort | if length == 0 then 0 else .[(length / 2 | floor)] end),
        ($v | sort | if length == 0 then 0 else .[((length * 0.9) | floor) | if . >= length then length - 1 else . end] end) ]
    | @tsv' "$OUT/dataset.json" 2>/dev/null) || die 'the dataset could not be read'
  local id total_s prs median p90 label fix owner hours_per_day
  local out='[]'
  while IFS=$'\t' read -r id total_s prs median p90; do
    [ -n "$id" ] || continue
    IFS=$'\t' read -r label fix owner <<<"$(jq -r --arg id "$id" \
      '[.stages[] | select(.id == $id) | [.label, .fix, .owner]][0] | @tsv' "$DEF" 2>/dev/null)"
    hours_per_day=$(awk -v s="$total_s" -v d="$WIN_DAYS" 'BEGIN { printf "%.4f", (s / 3600 / d) }')
    out=$(printf '%s' "$out" | jq -c --arg id "$id" --arg label "${label:-$id}" \
      --arg fix "$fix" --arg owner "${owner:-core}" \
      --argjson hours "$(awk -v s="$total_s" 'BEGIN { printf "%.1f", s / 3600 }')" \
      --argjson per_day "$hours_per_day" --argjson prs "$prs" \
      --argjson median "$median" --argjson p90 "$p90" \
      '. + [{stage: $id, label: $label, fix: $fix, owner: $owner, hours: $hours,
             hours_per_day: $per_day, prs: $prs, median_s: $median, p90_s: $p90}]')
  done <<EOF
$stage_rows
EOF
  out=$(printf '%s' "$out" | jq -c --argjson min "$(wf '.["min-hours-per-day"]')" '
    map(. + {ranked: (.hours_per_day >= $min)}) | sort_by(-.hours_per_day)')
  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  printf '%-40s %8s %8s %6s\n' stage hours h/day prs
  printf '%s' "$out" | jq -r '.[] | [.label, (.hours | tostring), (.hours_per_day | tostring), (.prs | tostring), (if .ranked then "" else "  (below the threshold)" end)] | @tsv' \
    | awk -F '\t' '{ printf "%-40s %8s %8s %6s%s\n", $1, $2, $3, $4, $5 }'
}

cmd_show() {
  local json
  json=$(cmd_rank --json "$@") || return 1
  jq -r --argjson d "$(jq -r '.window.days' "$OUT/dataset.json")" '
    "measured \(. | length) stage(s) over \($d) day(s)",
    (.[] | "  \(if .ranked then "*" else " " end) \(.label): \(.hours) h, \(.hours_per_day) h/day over \(.prs) pull request(s), median \(.median_s)s, p90 \(.p90_s)s -> \(.fix) [owner: \(.owner)]")' <<<"$json"
}

main() {
  local cmd=${1:-}
  shift 2>/dev/null || true
  command -v jq >/dev/null 2>&1 || die 'jq is required'
  DEF=$(definition) || die 'no throughput definition found'
  INPUTS=${INPUTS:-}
  case "$cmd" in
    fetch) cmd_fetch "$@" ;;
    measure) cmd_measure "$@" ;;
    rank) cmd_rank "$@" ;;
    show) cmd_show "$@" ;;
    *) die 'usage: jg-throughput.sh fetch | measure | rank [--json] | show' ;;
  esac
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
