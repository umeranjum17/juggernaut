#!/usr/bin/env bash
# auto-dispatch watcher check: every beat, write down which tickets this home would start by itself, and, with the home's
# switch on, start them. With the switch off (the default) it is watch only: it starts nothing.
# Usage: dispatch.sh check <jg-home>
#
# Free lanes are config/lane-target minus the ship and Recon lanes still working (the count bin/jg-fleet-heartbeat.sh makes);
# a home with no lane target has none. The candidates are the tickets `bin/jg-backlog.sh ready --spawnable` lists, plus every
# ticket that holds an approval record. A candidate is judged in this order, and the first reason that fits is the one written:
#   1. no approval record  state/dispatch-approved/<id>, written by `bin/jg-backlog.sh approve-dispatch` (a worker is refused
#      there); a line typed into a ticket body is never read, so it cannot approve anything;
#   2. a captain decision is open and linked to it (`bin/jg-captain-hold.sh blocking`; an answer that cannot be established also stops it);
#   3. it is not in the spawnable list (held, taken by a lane, closed, or its project is not this home's);
#   4. no brief  data/<id>/brief.md is missing or empty;
#   5. the approval record has no route (harness, model, effort);
#   6. no free lane is left for it.
# A ticket that passes all six is a "would start" row, in list order, as many as there are free lanes. The check writes no
# brief and picks no route.
# The switch is config/auto-dispatch: its first word `on` makes the check act, anything else or no file leaves it watch only.
# Switch on, each "would start" ticket is spawned through bin/jg-spawn.sh with the route of its approval record, as a ship
# lane in the delivery mode of its brief's `Delivery contract: mode=` line and the project's registered yolo posture, on the
# branch prefix its brief names. The spawn runs detached (it outlasts the check's bound) and its output is
# data/auto-dispatch/<id>.log. The row is then `started`. A start that left no lane record in 10 minutes, or a brief with no
# delivery contract, is a `spawn failed` or `skipped` row, and it is not tried again until the lead approves the ticket anew.
# The lane target, the quota gates and the brief gates stay: the spawn applies its own and may refuse.
# Switch on, the check prints ONE line a beat when a ticket newly needs the lead (no approval record, no brief, no route, no
# delivery contract, a failed start); the line wakes the lead, and data/auto-dispatch/told.tsv keeps a ticket from being named twice for the same reason.
# Output: the one file data/auto-dispatch/rows.tsv, one row per verdict CHANGE of a ticket:
#   <epoch><TAB><id><TAB>would start|skipped<TAB><route, or why>
# A beat that finds every ticket with the same verdict as its last row writes nothing. Watch only, the check prints nothing,
# so it wakes no one.
# Switch on, a ticket that passed all six reasons and still has no running start 10 minutes after its refusal (a brief with no
# delivery contract, an unreadable yolo posture, a failed start) raises the `ready-idle` alert through bin/jg-alert.sh, the
# alert table's own timer and rung, printed as the check's wake line; a start that takes resolves it. Watch only raises nothing.
# JG_AUTO_DISPATCH_BACKLOG, _HOLD, _SPAWN, _ALERT and _PROJECT_MODE name the backlog, captain-hold, spawn and project-mode commands
# (and JG_AUTO_DISPATCH_IN_FLIGHT the 600 seconds a start may take); tests point them at stand-ins.
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: dispatch.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=${JG_STATE_OVERRIDE:-$FMH/state}
DATA=${JG_DATA_OVERRIDE:-$FMH/data}
CONFIG=${JG_CONFIG_OVERRIDE:-$FMH/config}
BACKLOG=${JG_AUTO_DISPATCH_BACKLOG:-$FMH/bin/jg-backlog.sh}
HOLD=${JG_AUTO_DISPATCH_HOLD:-$FMH/bin/jg-captain-hold.sh}
SPAWN=${JG_AUTO_DISPATCH_SPAWN:-$FMH/bin/jg-spawn.sh}
PROJECT_MODE=${JG_AUTO_DISPATCH_PROJECT_MODE:-$FMH/bin/jg-project-mode.sh}
ALERT=${JG_AUTO_DISPATCH_ALERT:-$FMH/bin/jg-alert.sh}
TOLD=$DATA/auto-dispatch/told.tsv
APPROVED=$STATE/dispatch-approved
IN_FLIGHT_SECONDS=${JG_AUTO_DISPATCH_IN_FLIGHT:-600}
ROWS=$DATA/auto-dispatch/rows.tsv
umask 077
mkdir -p "$DATA/auto-dispatch" || exit 0
export JG_HOME=$FMH

# free_lanes: the target minus the working ship and Recon lanes; 0 when no target is set.
free_lanes() {
  local target working=0 meta kind last
  target=$(awk 'NF { print; exit }' "$CONFIG/lane-target" 2>/dev/null)
  case "$target" in ''|*[!0-9]*|0) echo 0; return ;; esac
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
    case "${kind:-ship}" in ship|scout) ;; *) continue ;; esac
    last=$(grep -E '^(working|paused|blocked|needs-decision|done|failed)[ :[]' "${meta%.meta}.status" 2>/dev/null | tail -1)
    case "$last" in paused*|blocked*|needs-decision*|done*|failed*) ;; *) working=$((working + 1)) ;; esac
  done
  [ "$working" -lt "$target" ] && echo $((target - working)) || echo 0
}

# approved_field <id> <field>: the field's value in the id's approval record.
approved_field() { sed -n "s/^$2=//p" "$APPROVED/$1" 2>/dev/null | tail -n 1; }

# verdict <id>: prints "route<TAB>..." when the ticket passes reasons 1 to 5, else "why<TAB>...".
verdict() {
  local id=$1 rc route
  [ -f "$APPROVED/$id" ] || { printf 'why\tno approval record\n'; return; }
  "$HOLD" blocking "$id" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) printf 'why\tan open decision is linked to it\n'; return ;;
    1) ;;
    *) printf 'why\tits open decisions could not be read\n'; return ;;
  esac
  grep -qx -- "$id" "$SPAWNABLE_IDS" || { printf 'why\tnot spawnable now (held, taken, closed, or not this home'"'"'s project)\n'; return; }
  [ -s "$DATA/$id/brief.md" ] || { printf 'why\tno brief\n'; return; }
  route="$(approved_field "$id" harness) $(approved_field "$id" model) $(approved_field "$id" effort)"
  case "$route" in ' '*|*'  '*|*' ') printf 'why\tthe approval record has no route\n'; return ;; esac
  printf 'route\t%s\n' "$route"
}

# last_row <id>: the "<epoch><TAB><kind><TAB><detail>" of the id's newest row.
last_row() { awk -F'\t' -v id="$1" '$2 == id { r = $1 "\t" $3 "\t" $4 } END { if (r != "") print r }' "$ROWS" 2>/dev/null; }
# last_verdict <id>: the "<kind><TAB><detail>" of that row.
last_verdict() { last_row "$1" | cut -f2-; }

# switch_on: the first word of config/auto-dispatch is `on`.
switch_on() { [ "$(awk 'NF { print $1; exit }' "$CONFIG/auto-dispatch" 2>/dev/null)" = on ]; }

# launch <id> <project> <route>: spawn the ticket detached through bin/jg-spawn.sh. Prints "started" and returns 0, or prints
# why it cannot be tried and returns 1.
launch() {
  local id=$1 project=$2 route=$3 brief=$DATA/$1/brief.md mode yolo branch task harness model effort
  local -a prefix=()
  mode=$(sed -n 's/^Delivery contract: mode=\([A-Za-z-]*\).*$/\1/p' "$brief" | head -n 1)
  [ -n "$mode" ] || { echo "the brief has no delivery contract line"; return 1; }
  yolo=$("$PROJECT_MODE" "$project" 2>/dev/null | awk '{ print $2 }')
  case "$yolo" in on|off) ;; *) echo "the project's registered yolo posture could not be read"; return 1 ;; esac
  read -r harness model effort <<< "$route"
  # shellcheck disable=SC2016  # the backquotes are the brief's own text
  branch=$(sed -n 's/^1\. First action: create your branch: `git checkout -b \([^ ]*\) --`.*$/\1/p' "$brief" | head -n 1)
  task=${id//./-}
  case "$branch" in *"$task") prefix=(--branch-prefix "${branch%"$task"}") ;; esac
  ( setsid nohup "$SPAWN" "$task" "$FMH/projects/$project" --ticket "$id" --mode "$mode" --yolo "$yolo" "${prefix[@]}" \
      --harness "$harness" --model "$model" --effort "$effort" > "$DATA/auto-dispatch/$id.log" 2>&1 < /dev/null & ) 2>/dev/null
  echo started
}

# needs_lead <kind> <detail>: a row whose cause only the lead can clear.
needs_lead() {
  [ "$1" != "spawn failed" ] || return 0
  case "$2" in "no approval record"|"no brief"|"the approval record has no route"|"the brief has no delivery contract line") return 0 ;; esac
  return 1
}

# ready_idle <id> <since-epoch>: a ticket the check may start has waited since <since> with a free lane. The alert row owns the
# 10-minute timer and refuses before it; its wake line (printed once per alert) goes to the lead's line.
ready_idle() {
  JG_STATE_OVERRIDE=$STATE "$ALERT" raise ready-idle "$1" --held $((now - $2)) --ticket "$1" --print \
    --note "$1 may start and a lane is free, but no start is running" 2>/dev/null >> "$tmp/alerts"
}

tmp=$(mktemp -d) || exit 0
trap 'rm -rf -- "$tmp"' EXIT
SPAWNABLE_IDS=$tmp/spawnable
"$BACKLOG" ready --spawnable > "$tmp/out" 2>/dev/null || exit 0   # the store could not answer: write nothing this beat
awk -F'\t' 'NF >= 2 { print $1 }' "$tmp/out" > "$SPAWNABLE_IDS"
{ cat "$SPAWNABLE_IDS"; for f in "$APPROVED"/*; do [ -f "$f" ] && basename "$f"; done; } 2>/dev/null | sort -u > "$tmp/candidates"

free=$(free_lanes)
now=$(date +%s)
started=0
ACT=0; ! switch_on || ACT=1
: > "$tmp/lead"; : > "$tmp/alerts"
# List order is the store's; approved tickets the list lacks come last, and they never start.
{ grep -Fx -f "$SPAWNABLE_IDS" "$tmp/candidates" 2>/dev/null; grep -Fvx -f "$SPAWNABLE_IDS" "$tmp/candidates" 2>/dev/null; } > "$tmp/ordered"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  prev=$(last_row "$id"); prev_epoch=${prev%%$'\t'*}; prev_kind=$(printf '%s' "$prev" | cut -f2)
  v=$(verdict "$id")
  # A start in flight holds its lane; one that left no lane record in IN_FLIGHT_SECONDS failed. A failed start waits for a new approval.
  if [ "$ACT" -eq 1 ] && [ "$prev_kind" = started ]; then
    case "$v" in route$'\t'*) ;; *) prev_kind=over ;; esac
    if [ "$prev_kind" = started ]; then
      if [ $((now - prev_epoch)) -lt "$IN_FLIGHT_SECONDS" ]; then started=$((started + 1)); continue; fi
      v=$(printf 'why\tspawn failed: no lane record after %s seconds (see data/auto-dispatch/%s.log)' "$IN_FLIGHT_SECONDS" "$id")
    fi
  fi
  if [ "$ACT" -eq 1 ] && [ "$prev_kind" = "spawn failed" ]; then
    [ "$(approved_field "$id" approved-at)" -gt "$prev_epoch" ] 2>/dev/null || { ready_idle "$id" "$prev_epoch"; continue; }
  fi
  idle=0
  case "$v" in
    route$'\t'*)
      if [ "$started" -ge "$free" ]; then row="skipped"$'\t'"no free lane left for it"
      elif [ "$ACT" -eq 0 ]; then started=$((started + 1)); row="would start"$'\t'"${v#route$'\t'}"
      elif why=$(launch "$id" "$(awk -F'\t' -v id="$id" '$1 == id { print $2 }' "$tmp/out")" "${v#route$'\t'}"); then
        started=$((started + 1)); row="started"$'\t'"${v#route$'\t'}"
      else row="skipped"$'\t'"$why"; idle=1; fi ;;
    why$'\t'spawn\ failed*) row="spawn failed"$'\t'"${v#why$'\t'spawn failed: }"; idle=1 ;;
    *) row="skipped"$'\t'"${v#why$'\t'}" ;;
  esac
  since=$now; [ "$(last_verdict "$id")" != "$row" ] || since=$prev_epoch
  [ "$(last_verdict "$id")" = "$row" ] || printf '%s\t%s\t%s\n' "$now" "$id" "$row" >> "$ROWS"
  if [ "$ACT" -eq 1 ] && [ "$idle" -eq 1 ]; then ready_idle "$id" "$since"; fi
  case "$row" in started$'\t'*) JG_STATE_OVERRIDE=$STATE "$ALERT" resolve "ready-idle--$id" >/dev/null 2>&1 ;; esac
  case "$row" in started$'\t'*) grep -v -F -- "$id"$'\t' "$TOLD" > "$tmp/told" 2>/dev/null; cat "$tmp/told" > "$TOLD" 2>/dev/null ;; esac
  if [ "$ACT" -eq 1 ] && needs_lead "${row%%$'\t'*}" "${row#*$'\t'}" && ! grep -qxF -- "$id"$'\t'"$row" "$TOLD" 2>/dev/null; then
    printf '%s\t%s\n' "$id" "$row" >> "$TOLD"; printf '%s (%s)\n' "$id" "${row#*$'\t'}" >> "$tmp/lead"
  fi
done < "$tmp/ordered"
cat "$tmp/alerts"
[ "$ACT" -eq 0 ] || [ ! -s "$tmp/lead" ] || printf 'auto-dispatch: lead, these tickets are not started by themselves: %s\n' "$(paste -sd';' "$tmp/lead" | sed 's/;/; /g')"
exit 0
