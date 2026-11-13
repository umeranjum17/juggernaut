#!/usr/bin/env bash
# lane-scale fleet: one budget for the host, in busy cores.
# Usage: fleet.sh verdict <jg-home>            print `go`, `stop <why>` or `hold <why>` and write state/fleet-budget.rec
#        fleet.sh slot take <jg-home> <id> [pid]   take one of `heavy_slots` for a heavy run; exit 1 when all are taken
#        fleet.sh slot give <jg-home> <id>         give the slot back
#        fleet.sh place <jg-home>                  print the machine that gets the next lane, or `stop <why>`; write state/fleet-machines.rec
# The busy cores are the cpu of the running processes, grouped in classes: lane (agent sessions), heavy (gate, test and proof runs),
# supervision (the watchers) and fault (any other process using 20% of a core or more: loops, browsers, shells). Only lane and heavy
# count against the budget, because only they stop when no lane starts; a fault never lowers the limit.
#   stop  lane + heavy cores reach `cores_stop`, or free memory is under `mem_floor_gb`, or every account is past its stop share
#         (quota.sh full): no lane starts. The reason names the class that is over its budget.
#   hold  the signal cannot be read (no process list, no memory figure) or the quota reader is blind (quota.sh blind): the limit holds.
#   go    otherwise.
# Config  config/lane-scale: cores_stop (75% of the host's cores), mem_floor_gb (8), heavy_slots (2).
# Machines  config/lane-scale-machines: one line `<name> <ssh target> <cores>` for each machine besides this host. They are under the SAME
#   budget: `place` reads each machine's process list over ssh (BatchMode, 5 s timeout, at most 16 reads at once, so 100 machines cost one
#   round of waits), counts lane + heavy cores per machine against that machine's own cores_stop share, and names the machine with the most
#   headroom (this host is `local`). A machine that cannot be read is skipped and named, never guessed; the budget is spent, so `stop`,
#   only when no machine has headroom. A `stop` or `hold` of the host's own verdict still decides for the host.
# Stand-ins JG_FLEET_SSH (a command run as `<it> <target>` in place of ssh; its output is the process list), JG_FLEET_PS (a command printing `<pcpu> <args>` lines), JG_FLEET_CORES, JG_FLEET_MEMINFO (a meminfo file).
set -u
export LC_ALL=C
case "${1:-}" in verdict|place) [ "$#" -eq 2 ] ;; slot) [ "$#" -ge 4 ] && case "$2" in take|give) true ;; *) false ;; esac ;; *) false ;; esac \
  || { echo "usage: fleet.sh verdict|place <jg-home> | slot take|give <jg-home> <id> [pid]" >&2; exit 2; }
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

# Busy cores by class, in hundredths of a core (integers all through).
classify() { awk '
  NF >= 2 && $1 ~ /^[0-9.]+$/ {
    c = $1 * 1; cmd = $2; sub(/.*\//, "", cmd); args = $0
    if (args ~ /done-done|jg-mem-gate|no-mistakes|shellcheck|\.test\.sh|gradle/) k = "heavy"
    else if (cmd ~ /^(claude|codex|opencode|pi|grok|kimi|cursor|omp|gemini)$/) k = "lane"
    else if (args ~ /jg-watch|jg-supervis/) k = "supervision"
    else if (c >= 20) k = "fault"
    else next
    sum[k] += c
  }
  END { for (k in sum) printf "%s %d\n", k, sum[k] }'; }
cores=${JG_FLEET_CORES:-$(nproc 2>/dev/null || echo 0)}
case "$cores" in ''|*[!0-9]*|0) cores=0 ;; esac
if [ "$CMD" = place ]; then
  list=$CONFIG/lane-scale-machines
  rows=$(mktemp -d "$STATE/.fleet-machines.XXXXXX") || exit 1
  trap 'rm -rf -- "$rows"' EXIT
  # shellcheck disable=SC2329 # run by name in the xargs child shell below
  read_machine() {  # <name> <target> <cores>: write one row `<name> read <counted cores> <stop cores>` or `<name> unread`
    local out
    out=$(if [ -n "${JG_FLEET_SSH:-}" ]; then timeout 5 bash -c "$JG_FLEET_SSH \"\$1\"" _ "$2"
          else timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=5 "$2" 'ps -eo pcpu=,args=' </dev/null; fi 2>/dev/null) && [ -n "$out" ] \
      || { echo "$1 unread" > "$rows/$1"; return; }
    local k l h; k=$(printf '%s\n' "$out" | classify)
    l=$(printf '%s\n' "$k" | awk '$1=="lane" {print $2}'); h=$(printf '%s\n' "$k" | awk '$1=="heavy" {print $2}')
    echo "$1 read $(( (${l:-0} + ${h:-0}) / 100 )) $(( $3 * $(conf cores_stop_pct 75) / 100 ))" > "$rows/$1"
  }
  export -f read_machine classify conf; export rows CONFIG JG_FLEET_SSH
  if [ -r "$list" ]; then
    # shellcheck disable=SC2016 # the xargs child shell expands these
    grep -v '^[[:space:]]*\(#\|$\)' "$list" | awk 'NF >= 3 && $1 !~ /[\/.]/ && $3 ~ /^[0-9]+$/' \
      | xargs -P 16 -L 1 bash -c 'read_machine "$0" "$1" "$2"'
  fi
  hv=$("$0" verdict "$FMH"); hrow=local
  case "$hv" in go*) ;; *) hrow= ;; esac
  [ -z "$hrow" ] || echo "local read $(( $(sed -n 's/^lane=//p' "$STATE/fleet-budget.rec") / 100 + $(sed -n 's/^heavy=//p' "$STATE/fleet-budget.rec") / 100 )) $(sed -n 's/^cores_stop=//p' "$STATE/fleet-budget.rec")" > "$rows/local"
  best=; room=0; unread=
  for f in "$rows"/*; do
    [ -f "$f" ] || continue
    read -r name state counted stop < "$f"
    if [ "$state" = unread ]; then unread="$unread $name"; continue; fi
    free=$(( stop - counted )); [ "$free" -gt "$room" ] && { room=$free; best=$name; }
  done
  tmp=$(mktemp "$STATE/.fleet-machines.XXXXXX.rec") || exit 0
  { printf 'place=%s\nroom=%s\nunread=%s\nhost=%s\n' "${best:-none}" "$room" "${unread# }" "$hv"; for f in "$rows"/*; do [ -f "$f" ] && sed 's/^/machine /' "$f"; done; } > "$tmp" && mv -f "$tmp" "$STATE/fleet-machines.rec"
  if [ -n "$best" ]; then printf '%s%s\n' "$best" "${unread:+ (unread: ${unread# })}"
  else printf 'stop no machine has a free core under its budget%s; host: %s\n' "${unread:+ (unread: ${unread# })}" "$hv"; fi
  exit 0
fi
ps_out=$(if [ -n "${JG_FLEET_PS:-}" ]; then bash -c "$JG_FLEET_PS"; else ps -eo pcpu=,args=; fi 2>/dev/null) || ps_out=
meminfo=${JG_FLEET_MEMINFO:-/proc/meminfo}
mem_kb=$(awk '/^MemAvailable:/ {print $2}' "$meminfo" 2>/dev/null)

classes=$(printf '%s\n' "$ps_out" | classify)
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
