#!/usr/bin/env bash
# tool-cpu.sh - which fleet scripts start the tool processes that take the most busy cores (H53).
#
#   tool-cpu.sh [--samples N] [--gap S] [--top N] [--min-cores C] [--ps-file F] [--daily] [--file-tickets]
#
# A sample is one read of the process table. For each mise (shim), gh, chromium and shellcheck process it walks the parent
# chain to the nearest shell that runs a .sh script and charges the process's CPU (ps pcpu / 100 = busy cores) to that
# script. Tool and shell processes without a script in between are skipped on the way up; a process with no script above it is
# reported as "(none) <nearest parent command>" and never gets a ticket. The cores of N samples S seconds apart are averaged.
#
# Prints one line per tool and caller, largest first: cores, tool, caller, processes seen per sample.
#   --samples N    snapshots to average (default 6)      --gap S     seconds between snapshots (default 5)
#   --top N        callers that rank "top" (default 5), by cores across all tools
#   --min-cores C  a top caller needs at least C cores in total (default 0.2)
#   --ps-file F    read "pid ppid pcpu comm args" lines from F instead of ps (every sample reads F; for tests)
#   --daily        take the sample once per UTC day: when data/metrics/tool-cpu.tsv already holds a row for today, print
#                  "already sampled <day>" and stop. Without it nothing is recorded.
#   --file-tickets file one ticket per top caller (needs --daily): tool-cpu-<script> with its numbers, through
#                  bin/jg-backlog.sh. While that ticket is open a second run files nothing and prints its id.
#
# The record is data/metrics/tool-cpu.tsv, append only: epoch, day, tool, caller, cores, processes. Read-only otherwise.
# The H29b filer (core/trunk-landing/quarantine.sh ticket) files flaky-test tickets only, so the ticket is filed here.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SELF_DIR/../.." && pwd -P)
JG_HOME="${JG_HOME:-$ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
BACKLOG="${JG_TOOL_CPU_BACKLOG:-$ROOT/bin/jg-backlog.sh}"
die() { echo "tool-cpu: $*" >&2; exit 2; }
usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

SAMPLES=6 GAP=5 TOP=5 MIN=0.2 PSFILE='' DAILY=0 FILE=0
num() { [[ ${2:-} =~ ^[0-9]+([.][0-9]+)?$ ]] || die "$1 needs a number, got '${2:-}'"; }
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --samples) num "$1" "${2:-}"; SAMPLES=${2%.*}; shift 2 ;;
    --gap) num "$1" "${2:-}"; GAP=$2; shift 2 ;;
    --top) num "$1" "${2:-}"; TOP=${2%.*}; shift 2 ;;
    --min-cores) num "$1" "${2:-}"; MIN=$2; shift 2 ;;
    --ps-file) [ -f "${2:-}" ] || die "--ps-file needs a readable file"; PSFILE=$2; shift 2 ;;
    --daily) DAILY=1; shift ;;
    --file-tickets) FILE=1; shift ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ "$SAMPLES" -ge 1 ] || die "--samples needs at least 1"
[ "$FILE" -eq 0 ] || [ "$DAILY" -eq 1 ] || die "--file-tickets needs --daily, so one day files once"

REC="$DATA/metrics/tool-cpu.tsv"
DAY=$(date -u +%F)
if [ "$DAILY" -eq 1 ] && [ -f "$REC" ] && awk -F'\t' -v d="$DAY" '$2 == d { f = 1 } END { exit !f }' "$REC"; then
  echo "already sampled $DAY"; exit 0
fi

T=$(mktemp -d) || die "no temp directory"
trap 'rm -rf -- "$T"' EXIT
snaps=()
for ((i = 1; i <= SAMPLES; i++)); do
  if [ -n "$PSFILE" ]; then cp "$PSFILE" "$T/s$i"
  else ps -eo pid=,ppid=,pcpu=,comm=,args= > "$T/s$i" || die "ps failed"; fi
  snaps+=("$T/s$i")
  [ "$i" -lt "$SAMPLES" ] && [ -z "$PSFILE" ] && sleep "$GAP"
done

# rows: tool<TAB>caller<TAB>cores<TAB>processes, cores and processes averaged over the samples.
awk -v n="$SAMPLES" '
  function tool_of(c) {
    if (c == "mise" || c == "gh" || c == "shellcheck") return c
    if (c ~ /^(chromium|chrome|chromium-browser|chrome-headless-shell|headless_shell)$/) return "chromium"
    return ""
  }
  function script_of(p,   a, k, m) {
    if (comm[p] !~ /^(bash|sh|dash|zsh)$/) return ""
    m = split(args[p], a, " ")
    for (k = 2; k <= m; k++) if (a[k] ~ /\.sh$/ && (a[k] ~ /\// || a[k] ~ /^jg-/)) { sub(/.*\//, "", a[k]); return a[k] }
    return ""
  }
  function caller(p,   q, d, s, fb) {
    fb = ""
    for (q = par[p]; q != "" && (q in comm) && d < 64; q = par[q]) {
      d++
      if (tool_of(comm[q]) != "") continue
      s = script_of(q)
      if (s != "") return s
      if (fb == "" && comm[q] !~ /^(bash|sh|dash|zsh)$/) fb = comm[q]
    }
    return "(none) " (fb == "" ? "unknown" : fb)
  }
  function close_snapshot(   i, p, t, k) {
    for (i = 1; i <= cnt; i++) {
      p = ord[i]; t = tool_of(comm[p]); if (t == "") continue
      k = t "\t" caller(p); cores[k] += cpu[p] / 100; procs[k]++
    }
    cnt = 0; delete comm; delete par; delete cpu; delete args; delete ord
  }
  FNR == 1 && NR > 1 { close_snapshot() }
  NF >= 4 && $1 ~ /^[0-9]+$/ {
    comm[$1] = $4; par[$1] = $2; cpu[$1] = $3 + 0; ord[++cnt] = $1
    a = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9.]+[ \t]+[^ \t]+[ \t]*/, "", a); args[$1] = $4 " " a
  }
  END {
    close_snapshot()
    for (k in cores) printf "%s\t%.2f\t%.1f\n", k, cores[k] / n, procs[k] / n
  }
' "${snaps[@]}" | sort -t$'\t' -k3,3nr -k1,1 -k2,2 > "$T/rows"

[ -s "$T/rows" ] || { echo "no tool processes seen in $SAMPLES sample(s)"; }
awk -F'\t' '{ printf "%6.2f cores  %-10s %s  (%s procs)\n", $3, $1, $2, $4 }' "$T/rows"

[ "$DAILY" -eq 1 ] || exit 0
mkdir -p "$DATA/metrics" || die "cannot write $DATA/metrics"
NOW=$(date +%s)
awk -F'\t' -v now="$NOW" -v day="$DAY" 'BEGIN { OFS = "\t" } { print now, day, $1, $2, $3, $4 }' "$T/rows" >> "$REC" \
  || die "cannot append to $REC"
# A sample that saw no tool process still records the day, so one day samples once.
[ -s "$T/rows" ] || printf '%s\t%s\t-\t-\t0.00\t0\n' "$NOW" "$DAY" >> "$REC"

[ "$FILE" -eq 1 ] || exit 0
# Top callers: fleet scripts only, ranked by cores across all tools.
awk -F'\t' -v min="$MIN" -v top="$TOP" '
  $2 !~ /^\(none\)/ { c[$2] += $3 }
  END { for (k in c) if (c[k] >= min) printf "%s\t%.2f\n", k, c[k] }
' "$T/rows" | sort -t$'\t' -k2,2nr -k1,1 | head -n "$TOP" > "$T/top"

while IFS=$'\t' read -r script total; do
  slug=$(printf '%s' "${script%.sh}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-')
  id="tool-cpu-$slug"
  if shown=$("$BACKLOG" show "$id" 2>/dev/null) && printf '%s\n' "$shown" | grep -q '^  closed: "-"'; then
    echo "open ticket $id for $script"; continue
  fi
  [ -z "${shown:-}" ] || id="$id-$NOW"   # the earlier ticket is closed and the script is still on top: a new one
  lines=$(awk -F'\t' -v s="$script" '$2 == s { printf "- %s: %.2f cores, %s processes at a time\n", $1, $3, $4 }' "$T/rows")
  "$BACKLOG" add "$id" "[perf] $script starts tool processes that take $total busy cores" --kind ship --priority 3 \
    --body "On $DAY, $script was a top caller of the processes that take the most busy cores (mean of $SAMPLES samples):
$lines
Why: tool processes (mise shims, gh, chromium, shellcheck) take about 4 to 6 busy cores of this host, more than the agents (H53).
Done when: $script starts fewer of these processes, or starts each one less often, and the next daily sample shows fewer cores." \
    >/dev/null 2>&1 || die "could not file the ticket $id for $script"
  echo "filed $id for $script ($total cores)"
done < "$T/top"
