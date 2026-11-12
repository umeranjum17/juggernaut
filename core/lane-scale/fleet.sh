#!/usr/bin/env bash
# lane-scale fleet: one budget for the host, in busy cores.
# Usage: fleet.sh verdict <jg-home>            print `go`, `stop <why>` or `hold <why>` and write state/fleet-budget.rec
#        fleet.sh slot take <jg-home> <id> [pid]   take one of `heavy_slots` for a heavy run; exit 1 when all are taken
#        fleet.sh slot give <jg-home> <id>         give the slot back
# The busy cores are the cpu of the running processes, grouped in classes: lane (agent sessions), heavy (gate, test and proof runs),
# supervision (the watchers) and fault (any other process using 20% of a core or more: loops, browsers, shells). Only lane and heavy
# count against the budget, because only they stop when no lane starts; a fault never lowers the limit.
#   stop  lane + heavy cores reach `cores_stop`, or free memory is under `mem_floor_gb`, or every account is past its stop share
#         (quota.sh full): no lane starts. The reason names the class that is over its budget.
#   hold  the signal cannot be read (no process list, no memory figure) or the quota reader is blind (quota.sh blind): the limit holds.
#   go    otherwise.
# Config  config/lane-scale: cores_stop (75% of the host's cores), mem_floor_gb (8), heavy_slots (2).
# Stand-ins JG_FLEET_PS (a command printing `<pcpu> <args>` lines), JG_FLEET_CORES, JG_FLEET_MEMINFO (a meminfo file).
set -u
export LC_ALL=C
case "${1:-}" in verdict) [ "$#" -eq 2 ] ;; slot) [ "$#" -ge 4 ] && case "$2" in take|give) true ;; *) false ;; esac ;; *) false ;; esac \
  || { echo "usage: fleet.sh verdict <jg-home> | slot take|give <jg-home> <id> [pid]" >&2; exit 2; }
CMD=$1; [ "$CMD" = slot ] && { SUB=$2; shift; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
[ -d "$2" ] || { echo "fleet.sh: no home $2" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=${JG_STATE_OVERRIDE:-$FMH/state}
CONFIG=${JG_CONFIG_OVERRIDE:-$FMH/config}
conf() { local v; v=$(sed -n "s/^$1=//p" "$CONFIG/lane-scale" 2>/dev/null | tail -n 1); case "$v" in ''|*[!0-9]*) echo "$2" ;; *) echo "$v" ;; esac; }
umask 077

if [ "$CMD" = slot ]; then
  dir=$STATE/heavy-slots; mkdir -p "$dir" || exit 1
  id=$3
  case "$id" in ''|*/*|.*) echo "fleet.sh: bad slot id" >&2; exit 2 ;; esac
  [ "$SUB" = give ] && { rm -f "$dir/$id"; exit 0; }
  # A slot whose run is gone is free again.
  for f in "$dir"/*; do [ -f "$f" ] && ! kill -0 "$(cat "$f")" 2>/dev/null && rm -f "$f"; done
  [ -f "$dir/$id" ] && exit 0
  n=$(find "$dir" -maxdepth 1 -type f | wc -l)
  [ "$n" -lt "$(conf heavy_slots 2)" ] || { echo "fleet.sh: all $(conf heavy_slots 2) heavy slots are taken" >&2; exit 1; }
  printf '%s\n' "${4:-$PPID}" > "$dir/$id"; exit 0
fi

cores=${JG_FLEET_CORES:-$(nproc 2>/dev/null || echo 0)}
case "$cores" in ''|*[!0-9]*|0) cores=0 ;; esac
ps_out=$(if [ -n "${JG_FLEET_PS:-}" ]; then bash -c "$JG_FLEET_PS"; else ps -eo pcpu=,args=; fi 2>/dev/null) || ps_out=
meminfo=${JG_FLEET_MEMINFO:-/proc/meminfo}
mem_kb=$(awk '/^MemAvailable:/ {print $2}' "$meminfo" 2>/dev/null)

# Busy cores by class, in hundredths of a core (integers all through).
classes=$(printf '%s\n' "$ps_out" | awk '
  NF >= 2 && $1 ~ /^[0-9.]+$/ {
    c = $1 * 1; cmd = $2; sub(/.*\//, "", cmd); args = $0
    if (args ~ /done-done|jg-mem-gate|no-mistakes|shellcheck|\.test\.sh|gradle/) k = "heavy"
    else if (cmd ~ /^(claude|codex|opencode|pi|grok|kimi|cursor|omp|gemini)$/) k = "lane"
    else if (args ~ /jg-watch|jg-supervis/) k = "supervision"
    else if (c >= 20) k = "fault"
    else next
    sum[k] += c
  }
  END { for (k in sum) printf "%s %d\n", k, sum[k] }')
cls() { printf '%s\n' "$classes" | awk -v k="$1" '$1==k {print $2; f=1} END {if (!f) print 0}'; }
lane=$(cls lane); heavy=$(cls heavy); sup=$(cls supervision); fault=$(cls fault)
cores_stop=$(conf cores_stop $(( cores * 75 / 100 )))
mem_floor=$(conf mem_floor_gb 8)
counted=$(( (lane + heavy) / 100 ))

verdict=go; why=
if [ "$cores" -eq 0 ] || [ -z "$ps_out" ] || [ -z "${mem_kb:-}" ]; then verdict=hold; why="the host signal cannot be read"
elif [ "$counted" -ge "$cores_stop" ]; then
  verdict=stop; over=lane; [ "$heavy" -le "$lane" ] || over=heavy
  why="$counted of $cores busy cores are lane and heavy runs, over $cores_stop; the $over class is the largest"
elif [ $(( mem_kb / 1048576 )) -lt "$mem_floor" ]; then verdict=stop; why="free memory $(( mem_kb / 1048576 )) GB is under $mem_floor GB"
elif "$HERE/quota.sh" full "$FMH" >/dev/null 2>&1; then verdict=stop; why="every account is past its stop share"
elif "$HERE/quota.sh" blind "$FMH"; then verdict=hold; why="the quota reader is blind"
fi

tmp=$(mktemp "$STATE/.fleet-budget.XXXXXX") || exit 0
printf 'verdict=%s\nwhy=%s\ncores=%s\nlane=%s\nheavy=%s\nsupervision=%s\nfault=%s\ncores_stop=%s\n' \
  "$verdict" "$why" "$cores" "$lane" "$heavy" "$sup" "$fault" "$cores_stop" > "$tmp" && mv -f "$tmp" "$STATE/fleet-budget.rec"
printf '%s%s\n' "$verdict" "${why:+ $why}"
