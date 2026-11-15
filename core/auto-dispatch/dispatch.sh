#!/usr/bin/env bash
# auto-dispatch watcher check: every beat, write down which tickets this home would start by itself, and, with the home's
# switch on, start them. With the switch off (the default) it is watch only: it starts nothing.
# Usage: dispatch.sh check <jg-home>
#        dispatch.sh state <jg-home> <id>        print the start state of an approved ticket (the machine's observer)
#        dispatch.sh run <jg-home> <record> <task> <log> <spawn command...>   the detached wrapper of one start
#
# Free lanes are the lane target (config/lane-target, or the lane limit once config/lane-scale says `mode=act`; core/lane-scale) minus the ship and Recon lanes still working (the count bin/jg-fleet-heartbeat.sh makes);
# a home with no lane target has none. The candidates are the tickets `bin/jg-backlog.sh ready --spawnable` lists, plus every
# ticket that holds an approval record. A candidate is judged in this order, and the first reason that fits is the one written:
#   1. no approval record  state/dispatch-approved/<id>, written by `bin/jg-backlog.sh approve-dispatch` (a worker is refused
#      there); a line typed into a ticket body is never read, so it cannot approve anything;
#   2. a captain decision is open and linked to it (`bin/jg-captain-hold.sh blocking`; an answer that cannot be established also stops it);
#   3. it is not in the spawnable list (held, taken by a lane, closed, or its project is not this home's);
#   4. no brief  data/<id>/brief.md is missing or empty;
#   5. the approval record has no route (harness, model, effort);
#   6. no free lane is left for it;
#   7. no free copy: with the switch on, core/pool-reserve/reserve.sh `admit` refuses a copy of its project (the lane limit and the
#      two copies kept for a red fix). That is a wait, not a failure: the row says so, nothing is spawned, and a later beat starts it.
# A ticket that passes all six is a "would start" row, in list order, as many as there are free lanes. The check writes no
# brief and picks no route.
# The switch is config/auto-dispatch: its first word `on` makes the check act, anything else or no file leaves it watch only.
# Switch on, each "would start" ticket is spawned through bin/jg-spawn.sh with the route of its approval record, as a ship
# lane in the delivery mode of its brief's `Delivery contract: mode=` line and the project's registered yolo posture, on the
# branch prefix its brief names. The spawn runs detached (it outlasts the check's bound) under `dispatch.sh run`, which
# writes what the spawn really did into the start record data/auto-dispatch/<id>.start.<attempt> (the spawn's output is
# data/auto-dispatch/<id>.log). The spawn's exit is the result, and the row follows the result, never the launch:
#   0   started   the lane record state/<task>.meta is there (an exit 0 with no lane record is a failed start);
#   75  deferred  the spawn said wait (pool full, no copy, load, capacity, a locked task set): the NEXT BEAT STARTS IT AGAIN under
#               the same approval, as the next attempt, with no lead turn and no new approval;
#   else failed   the spawn's last line is the cause: named to the lead once, and not tried again until a new approval.
# Before a launch the check asks the ready state again: a lane record already there means the ticket is running (no spawn), and a
# start record of the ticket without a result is a start in flight (no second spawn). Each attempt is claimed by creating its
# record with noclobber, so two check runs, or a restart, start a ticket once. A start whose wrapper left no result in 10
# minutes is read from the lane record: there is one, it started; there is none, it failed.
# core/machines/tables/dispatch-start.tsv is the table of these states (ready, starting, started, deferred, refused);
# `dispatch.sh state <jg-home> <id>` is its observer.
# The lane target, the quota gates and the brief gates stay: the spawn applies its own and may refuse.
# Switch on, the check prints ONE line a beat when a ticket newly needs the lead (no approval record, no brief, no route, no
# delivery contract, a failed start); the line wakes the lead, and data/auto-dispatch/told.tsv keeps a ticket from being named twice for the same reason.
# Output: the one file data/auto-dispatch/rows.tsv, one row per verdict CHANGE of a ticket:
#   <epoch><TAB><id><TAB>would start|skipped|starting|started|deferred|spawn failed<TAB><route, or why>
# A beat that finds every ticket with the same verdict as its last row writes nothing. Watch only, the check prints nothing,
# so it wakes no one.
# Switch on, a ticket that passed all six reasons and still has no running start 10 minutes after its refusal (a brief with no
# delivery contract, an unreadable yolo posture, a failed start) raises the `ready-idle` alert through bin/jg-alert.sh, the
# alert table's own timer and rung, printed as the check's wake line; a start that takes resolves it. Watch only raises nothing.
# JG_AUTO_DISPATCH_BACKLOG, _HOLD, _SPAWN, _ALERT and _PROJECT_MODE name the backlog, captain-hold, spawn and project-mode commands
# (and JG_AUTO_DISPATCH_IN_FLIGHT the 600 seconds a start may take); tests point them at stand-ins.
set -u
case "${1:-}" in
  check) [ "$#" -eq 2 ] ;;
  state) [ "$#" -eq 3 ] ;;
  run) [ "$#" -ge 6 ] ;;
  *) false ;;
esac && [ -d "$2/state" ] || { echo "usage: dispatch.sh check <jg-home> | state <jg-home> <id> | run <jg-home> <record> <task> <log> <spawn command...>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")
STATE=${JG_STATE_OVERRIDE:-$FMH/state}
DATA=${JG_DATA_OVERRIDE:-$FMH/data}
CONFIG=${JG_CONFIG_OVERRIDE:-$FMH/config}
BACKLOG=${JG_AUTO_DISPATCH_BACKLOG:-$FMH/bin/jg-backlog.sh}
HOLD=${JG_AUTO_DISPATCH_HOLD:-$FMH/bin/jg-captain-hold.sh}
SPAWN=${JG_AUTO_DISPATCH_SPAWN:-$FMH/bin/jg-spawn.sh}
PROJECT_MODE=${JG_AUTO_DISPATCH_PROJECT_MODE:-$FMH/bin/jg-project-mode.sh}
ALERT=${JG_AUTO_DISPATCH_ALERT:-$FMH/bin/jg-alert.sh}
RESERVE=${JG_AUTO_DISPATCH_RESERVE:-$FMH/core/pool-reserve/reserve.sh}
TOLD=$DATA/auto-dispatch/told.tsv
SCALE=${JG_AUTO_DISPATCH_SCALE:-$FMH/core/lane-scale/scale.sh}
APPROVED=$STATE/dispatch-approved
IN_FLIGHT_SECONDS=${JG_AUTO_DISPATCH_IN_FLIGHT:-600}
ROWS=$DATA/auto-dispatch/rows.tsv
umask 077
mkdir -p "$DATA/auto-dispatch" || exit 0
export JG_HOME=$FMH

# lane_target: the home's lane target. core/lane-scale/scale.sh owns it: the lane limit when the home's mode is `act`,
# else config/lane-target; a home without the scaler reads config/lane-target itself.
lane_target() {
  if [ -x "$SCALE" ]; then "$SCALE" target "$FMH" 2>/dev/null
  else awk 'NF { print; exit }' "$CONFIG/lane-target" 2>/dev/null; fi
}

# free_lanes: the target minus the working ship and Recon lanes; 0 when no target is set.
free_lanes() {
  local target working=0 meta kind last
  target=$(lane_target)
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

# ---- The start record: one file for each attempt to start a ticket, data/auto-dispatch/<id>.start.<attempt>.
# `launch` creates it (key=value lines: attempt, task, approved-at, launched-at, route) and `run_start` adds the result
# (result, rc, ended-at, reason) when the spawn ends. The state of a ticket's start is read from its newest record and
# the lane record, never stored: core/machines/tables/dispatch-start.tsv names the states and the moves.
START_PREFIX=$DATA/auto-dispatch

# start_field <record> <key>: the key's value in a start record.
start_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }

# latest_attempt <id>: the number of the id's newest start record, 0 when it has none.
latest_attempt() {
  local f n best=0
  for f in "$START_PREFIX/$1".start.*; do
    [ -f "$f" ] || continue
    n=${f##*.start.}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -le "$best" ] || best=$n
  done
  echo "$best"
}

# lane_record <task>: the task's published lane record (a record that only keeps a failed launch's copy is not one).
lane_record() { [ -f "$STATE/$1.meta" ] && ! grep -q '^cleanup_recovery=' "$STATE/$1.meta" 2>/dev/null; }

# start_state <id>: sets START_STATE (ready, starting, started, deferred or refused) and START_WHY (the cause of a deferral
# or a refusal). Needs $now.
START_STATE=ready; START_WHY=
start_state() {
  local id=$1 rec result task launched approved current
  START_STATE=ready; START_WHY=
  rec=$START_PREFIX/$id.start.$(latest_attempt "$id")
  [ -f "$rec" ] || return 0
  task=$(start_field "$rec" task); result=$(start_field "$rec" result)
  if [ -z "$result" ]; then
    # No result yet: the wrapper is still running the spawn, or it died. The lane record settles a dead wrapper.
    launched=$(start_field "$rec" launched-at)
    if [ $((now - ${launched:-0})) -lt "$IN_FLIGHT_SECONDS" ]; then START_STATE=starting
    elif lane_record "$task"; then START_STATE=started
    else START_STATE=refused; START_WHY="the start left no result in $IN_FLIGHT_SECONDS seconds (see data/auto-dispatch/$id.log)"; fi
    return 0
  fi
  # A result belongs to the approval it was started under; a newer approval starts over.
  approved=$(start_field "$rec" approved-at); current=$(approved_field "$id" approved-at)
  if [ "${current:-0}" -gt "${approved:-0}" ] 2>/dev/null; then return 0; fi
  START_STATE=$result; START_WHY=$(start_field "$rec" reason)
}

# last_line <log>: the last line of the spawn's output as one short line with no tab.
last_line() { grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | tr '\t\r' '  ' | cut -c1-200; }

# run_start <record> <task> <log> <spawn command...>: the detached wrapper of one start. It runs the spawn and writes what the
# spawn really did into the record: the exit 0 with the lane record there is `started`, the exit 75 is `deferred` (the spawn
# said wait; the next beat starts it again), anything else is `refused` with the spawn's last line as its cause.
run_start() {
  local rec=$1 task=$2 log=$3 rc=0 result reason=
  shift 3
  "$@" > "$log" 2>&1 < /dev/null || rc=$?
  case "$rc" in
    0) if lane_record "$task"; then result=started; else result=refused; reason="the spawn exited 0 and left no lane record"; fi ;;
    75) result=deferred; reason=$(last_line "$log") ;;
    *) result=refused; reason=$(last_line "$log") ;;
  esac
  [ -n "$reason" ] || [ "$result" = started ] || reason="the spawn exited $rc with no output"
  { cat "$rec"; printf 'result=%s\nrc=%s\nended-at=%s\nreason=%s\n' "$result" "$rc" "$(date +%s)" "$reason"; } > "$rec.tmp.$$" \
    && mv -f "$rec.tmp.$$" "$rec"
}

# launch <id> <project> <route>: claim the next attempt for the ticket and spawn it detached through `run_start`. Prints
# "starting" and returns 0, or prints why it cannot be tried and returns 1. A claim another run won is a start in flight.
launch() {
  local id=$1 project=$2 route=$3 brief=$DATA/$1/brief.md mode yolo branch task harness model effort attempt rec
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
  attempt=$(( $(latest_attempt "$id") + 1 )); rec=$START_PREFIX/$id.start.$attempt
  # One create claims the attempt: a second run, or a restart, that reads the same count loses here and starts nothing.
  if ! ( set -C; printf 'attempt=%s\ntask=%s\napproved-at=%s\nlaunched-at=%s\nroute=%s\n' \
      "$attempt" "$task" "$(approved_field "$id" approved-at)" "$now" "$route" > "$rec" ) 2>/dev/null; then echo starting; return 0; fi
  rm -f "$START_PREFIX/$id.start.$((attempt - 3))"   # a deferral retried each beat keeps its last three attempts, not all of them
  ( setsid nohup bash "$SELF" run "$FMH" "$rec" "$task" "$DATA/auto-dispatch/$id.log" \
      "$SPAWN" "$task" "$FMH/projects/$project" --ticket "$id" --mode "$mode" --yolo "$yolo" "${prefix[@]}" \
      --harness "$harness" --model "$model" --effort "$effort" > /dev/null 2>&1 < /dev/null & ) 2>/dev/null
  echo starting
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

case "$1" in
  run) shift 2; run_start "$@"; exit $? ;;
  state) now=$(date +%s); [ -f "$APPROVED/$3" ] || exit 0; start_state "$3"; echo "$START_STATE"; exit 0 ;;
esac

tmp=$(mktemp -d) || exit 0
trap 'rm -rf -- "$tmp"' EXIT
SPAWNABLE_IDS=$tmp/spawnable
"$BACKLOG" ready --spawnable > "$tmp/out" 2>/dev/null || exit 0   # the store could not answer: write nothing this beat
awk -F'\t' 'NF >= 2 { print $1 }' "$tmp/out" > "$SPAWNABLE_IDS"
for f in "$APPROVED"/*; do [ -f "$f" ] && basename "$f"; done 2>/dev/null | sort -u > "$tmp/approved"

[ ! -x "$SCALE" ] || "$SCALE" check "$FMH" >/dev/null 2>&1   # the lane limit takes its tick on this beat
free=$(free_lanes)
now=$(date +%s)
started=0
ACT=0; ! switch_on || ACT=1
: > "$tmp/lead"; : > "$tmp/alerts"
# List order is the store's priority order and is kept as it is (no sort); approved tickets the list lacks come last, and they never start.
awk '!seen[$0]++' "$SPAWNABLE_IDS" "$tmp/approved" > "$tmp/ordered"
# record_row <id> <idle 0|1> <kind> <detail>: write the ticket's row when its verdict changed, and do what the row asks: a row the
# check may not leave raises ready-idle, a started row clears the alert and the lead's note, a row the lead must clear is named once.
record_row() {
  local id=$1 idle=$2 row=$3$'\t'$4 since
  since=$now; [ "$(last_verdict "$id")" != "$row" ] || since=$prev_epoch
  [ "$(last_verdict "$id")" = "$row" ] || printf '%s\t%s\t%s\n' "$now" "$id" "$row" >> "$ROWS"
  if [ "$ACT" -eq 1 ] && [ "$idle" -eq 1 ]; then ready_idle "$id" "$since"; fi
  case "$row" in started$'\t'*) JG_STATE_OVERRIDE=$STATE "$ALERT" resolve "ready-idle--$id" >/dev/null 2>&1 ;; esac
  case "$row" in started$'\t'*) grep -v -F -- "$id"$'\t' "$TOLD" > "$tmp/told" 2>/dev/null; cat "$tmp/told" > "$TOLD" 2>/dev/null ;; esac
  if [ "$ACT" -eq 1 ] && needs_lead "${row%%$'\t'*}" "${row#*$'\t'}" && ! grep -qxF -- "$id"$'\t'"$row" "$TOLD" 2>/dev/null; then
    printf '%s\t%s\n' "$id" "$row" >> "$TOLD"; printf '%s (%s)\n' "$id" "${row#*$'\t'}" >> "$tmp/lead"
  fi
}

# route_of <id>: the route of the id's approval record.
route_of() { printf '%s %s %s' "$(approved_field "$1" harness)" "$(approved_field "$1" model)" "$(approved_field "$1" effort)"; }

while IFS= read -r id; do
  [ -n "$id" ] || continue
  prev=$(last_row "$id"); prev_epoch=${prev%%$'\t'*}
  v=$(verdict "$id")
  task=${id//./-}
  if [ "$ACT" -eq 1 ]; then
    # The start's own record says how the last start ended, and the lane record says whether the ticket already runs. The
    # spawn's result decides the row; the launch never does.
    start_state "$id"
    case "$START_STATE" in
      starting) started=$((started + 1)); continue ;;                    # in flight: it holds its lane and is never started twice
      started) record_row "$id" 0 started "$(route_of "$id")"; continue ;; # the lane record is there, so the lane counts itself
      refused) record_row "$id" 1 "spawn failed" "$START_WHY"; continue ;; # a failed start waits for a new approval
      deferred) record_row "$id" 0 deferred "$START_WHY" ;;              # the spawn said wait: the same approval starts it again below
    esac
    if lane_record "$task"; then record_row "$id" 0 started "its lane is already running"; continue; fi   # started by another path
  fi
  kind=skipped; idle=0; waits=0
  case "$v" in
    route$'\t'*)
      if [ "$started" -ge "$free" ]; then detail="no free lane left for it"; waits=1
      elif [ "$ACT" -eq 0 ]; then started=$((started + 1)); kind="would start"; detail=${v#route$'\t'}
      elif [ -x "$RESERVE" ] && ! admit_err=$("$RESERVE" admit "$FMH" "$FMH/projects/$(awk -F'\t' -v id="$id" '$1 == id { print $2 }' "$tmp/out")" 2>&1 >/dev/null); then
        case "$admit_err" in
          *"cannot be counted"*) detail="copy count unknown (the pool could not be read; the next beat retries)" ;;
          *) detail="no free copy (the copies left are kept for a red fix)" ;;
        esac
        waits=1
      elif detail=$(launch "$id" "$(awk -F'\t' -v id="$id" '$1 == id { print $2 }' "$tmp/out")" "${v#route$'\t'}"); then
        started=$((started + 1)); kind=starting; detail=${v#route$'\t'}
      else idle=1; fi ;;
    *) detail=${v#why$'\t'} ;;
  esac
  # A deferred ticket that waits for a lane or a copy keeps its deferred row; the wait is not a new verdict.
  [ "$START_STATE" != deferred ] || [ "$waits" -eq 0 ] || continue
  record_row "$id" "$idle" "$kind" "$detail"
done < "$tmp/ordered"
cat "$tmp/alerts"
[ "$ACT" -eq 0 ] || [ ! -s "$tmp/lead" ] || printf 'auto-dispatch: lead, these tickets are not started by themselves: %s\n' "$(paste -sd';' "$tmp/lead" | sed 's/;/; /g')"
exit 0
