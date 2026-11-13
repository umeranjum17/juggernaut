#!/usr/bin/env bash
# lane-scale: the lane limit of a home follows its work.
# Usage: scale.sh check <jg-home>    one tick (the watcher runs it each beat): compute and write the home's lane limit
#        scale.sh target <jg-home>   print the lane target the refill and the fleet heartbeat read: the limit when the
#                                    home's mode is `act` and the limit is fresh, else config/lane-target ("-" when none)
# Work is the ship and Recon lanes still working plus the tickets the home could start now (a ticket in
# `bin/jg-backlog.sh ready --spawnable` that holds an approval record and a brief, the same tickets dispatch.sh would start).
# The wanted limit is 0 with no work, else the work between `min` and `max`. The limit climbs `step_up` a tick, and a step waits
# `step_period` seconds. It falls only after `down_window` seconds in which the wanted value stayed lower, and then to the highest
# wanted value of that window. It never falls below the working lanes it was last told of: a lower limit only means nothing new
# starts, and this script ends no lane and touches no copy.
# Config  config/lane-scale, key=value lines: min (0), max (the lane target, else 10), step_up (2), step_period (60),
#         down_window (300), mode (report | act, default report). No file: the home is not scaled, no limit is written.
# Records state/lane-limit (one integer, what `target` reads) and state/lane-scale.rec (the machine's own fields:
#         limit, stepped_at, down_since, down_high, and the work seen). `mode=report` writes both and changes no refill.
# JG_LANE_SCALE_BACKLOG names the backlog command and JG_LANE_SCALE_NOW the clock (a test points them at stand-ins).
set -u
case "${1:-}" in check|target) ;; *) echo "usage: scale.sh check|target <jg-home>" >&2; exit 2 ;; esac
[ "$#" -eq 2 ] && [ -d "$2" ] || { echo "usage: scale.sh check|target <jg-home>" >&2; exit 2; }
CMD=$1
FMH=$(cd "$2" && pwd -P)
STATE=${JG_STATE_OVERRIDE:-$FMH/state}
CONFIG=${JG_CONFIG_OVERRIDE:-$FMH/config}
BACKLOG=${JG_LANE_SCALE_BACKLOG:-$FMH/bin/jg-backlog.sh}
LIMIT=$STATE/lane-limit
REC=$STATE/lane-scale.rec
FRESH_SECONDS=600
now() { echo "${JG_LANE_SCALE_NOW:-$(date +%s)}"; }

# conf <key> <default>: the key's value in config/lane-scale, else the default.
conf() { local v; v=$(sed -n "s/^$1=//p" "$CONFIG/lane-scale" 2>/dev/null | tail -n 1); echo "${v:-$2}"; }
# fixed_target: config/lane-target, "-" when none is set.
fixed_target() {
  local t; t=$(awk 'NF { print; exit }' "$CONFIG/lane-target" 2>/dev/null)
  case "$t" in ''|*[!0-9]*|0) echo - ;; *) echo "$t" ;; esac
}
num() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }

if [ "$CMD" = target ]; then
  limit=$(awk 'NF { print; exit }' "$LIMIT" 2>/dev/null)
  mtime=$(stat -c %Y "$LIMIT" 2>/dev/null || stat -f %m "$LIMIT" 2>/dev/null || echo 0)
  case "$limit" in ''|*[!0-9]*) fixed_target; exit 0 ;; esac
  if [ "$(conf mode report)" = act ] && [ $(( $(now) - mtime )) -le "$FRESH_SECONDS" ]; then
    [ "$limit" -gt 0 ] && echo "$limit" || echo -
  else
    fixed_target
  fi
  exit 0
fi

# check: no config file, no scaling.
[ -f "$CONFIG/lane-scale" ] || exit 0
umask 077
fixed=$(fixed_target)
min=$(num "$(conf min 0)" 0)
max=$(num "$(conf max "${fixed/-/10}")" 10)
step=$(num "$(conf step_up 2)" 2); [ "$step" -gt 0 ] || step=2
period=$(num "$(conf step_period 60)" 60)
window=$(num "$(conf down_window 300)" 300)
[ "$min" -le "$max" ] || min=$max

working=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
  case "${kind:-ship}" in ship|scout) ;; *) continue ;; esac
  last=$(grep -E '^(working|paused|blocked|needs-decision|done|failed)[ :[]' "${meta%.meta}.status" 2>/dev/null | tail -1)
  case "$last" in paused*|blocked*|needs-decision*|done*|failed*) ;; *) working=$((working + 1)) ;; esac
done
# The store could not answer: the limit holds, it is not recomputed from a guess.
out=$("$BACKLOG" ready --spawnable 2>/dev/null) || exit 0
startable=0
while IFS=$'\t' read -r id _; do
  [ -n "$id" ] && [ -f "$STATE/dispatch-approved/$id" ] && [ -s "${JG_DATA_OVERRIDE:-$FMH/data}/$id/brief.md" ] && startable=$((startable + 1))
done <<< "$out"

work=$((working + startable))
if [ "$work" -eq 0 ]; then want=0
else want=$work; [ "$want" -ge "$min" ] || want=$min; [ "$want" -le "$max" ] || want=$max; fi

limit=$(num "$(sed -n 's/^limit=//p' "$REC" 2>/dev/null)" 0)
stepped=$(num "$(sed -n 's/^stepped_at=//p' "$REC" 2>/dev/null)" 0)
down_since=$(num "$(sed -n 's/^down_since=//p' "$REC" 2>/dev/null)" 0)
down_high=$(num "$(sed -n 's/^down_high=//p' "$REC" 2>/dev/null)" 0)
t=$(now)
# A limit never starts below the lanes already working: the first rung is where the home is.
[ "$limit" -ge "$working" ] || limit=$(( working < max ? working : max ))

if [ "$want" -gt "$limit" ]; then
  down_since=0; down_high=0
  if [ $((t - stepped)) -ge "$period" ]; then
    limit=$((limit + step)); [ "$limit" -le "$want" ] || limit=$want
    stepped=$t
  fi
elif [ "$want" -lt "$limit" ]; then
  if [ "$down_since" -eq 0 ]; then down_since=$t; down_high=$want
  elif [ "$want" -gt "$down_high" ]; then down_high=$want; fi
  if [ $((t - down_since)) -ge "$window" ]; then limit=$down_high; down_since=0; down_high=0; stepped=$t; fi
else
  down_since=0; down_high=0
fi

tmp=$(mktemp "$STATE/.lane-scale.XXXXXX") || exit 0
printf 'limit=%s\nstepped_at=%s\ndown_since=%s\ndown_high=%s\nworking=%s\nstartable=%s\nwant=%s\nmode=%s\n' \
  "$limit" "$stepped" "$down_since" "$down_high" "$working" "$startable" "$want" "$(conf mode report)" > "$tmp" && mv -f "$tmp" "$REC"
tmp=$(mktemp "$STATE/.lane-scale.XXXXXX") || exit 0
printf '%s\n' "$limit" > "$tmp" && mv -f "$tmp" "$LIMIT"
