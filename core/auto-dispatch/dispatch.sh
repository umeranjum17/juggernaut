#!/usr/bin/env bash
# auto-dispatch watcher check: every beat, write down which tickets this home would start by itself, and, with the home's
# switch on, start them. With the switch off (the default) it is watch only: it starts nothing.
# Usage: dispatch.sh check <jg-home>
#        dispatch.sh pass <jg-home>              one pass of the check, with no lock (the check's own step)
#        dispatch.sh state <jg-home> <id>        print the start state of an approved ticket (the machine's observer)
#        dispatch.sh run <jg-home> <record> <task> <log> <spawn command...>   the detached wrapper of one start
#
# Free lanes are the lane target (config/lane-target, or the lane limit once config/lane-scale says `mode=act`; core/lane-scale) minus the ship and Recon lanes still working (the count bin/jg-fleet-heartbeat.sh makes);
# a home with no lane target has none. The candidates are the tickets `bin/jg-backlog.sh ready --spawnable` lists, plus every
# ticket that holds an approval record. A candidate is judged in this order, and the first reason that fits is the one written:
#   1. no approval record  state/dispatch-approved/<id>, written by `bin/jg-backlog.sh approve-dispatch` (a worker is refused
#      there); a line typed into a ticket body is never read, so it cannot approve anything;
#   2. a captain decision is open and linked to it (one `bin/jg-captain-hold.sh blocking --batch` read per pass; an unread batch stops it);
#   3. it is not in the spawnable list (held, taken by a lane, closed, or its project is not this home's);
#   4. no brief  data/<id>/brief.md is missing or empty;
#   5. the approval record has no route (harness, model, effort);
#   6. no free lane is left for it;
#   7. no free copy: with the switch on, core/pool-reserve/reserve.sh `admit` checks each eligible project once per pass (the lane
#      limit and two copies kept for a red fix). If it refuses, the project waits for a later beat.
# A ticket that passes all six is a "would start" row, in list order, as many as there are free lanes. The check writes no
# brief and picks no route.
# The switch is config/auto-dispatch: its first word `on` makes the check act, anything else or no file leaves it watch only.
# Switch on, each "would start" ticket is spawned through bin/jg-spawn.sh with the route of its approval record, as a ship
# lane in the delivery mode of its brief's `Delivery contract: mode=` line and the project's registered yolo posture, on the
# branch prefix its brief names; a brief that carries the Recon contract line (bin/jg-brief.sh --scout writes it) is spawned as a
# Recon lane with `--scout` and no mode, yolo or branch prefix. The spawn runs detached (it outlasts the check's bound) under `dispatch.sh run`, which
# writes what the spawn really did into the start record data/auto-dispatch/<id>.start.<attempt> (the spawn's output is
# data/auto-dispatch/<id>.log). The spawn's exit is the result, and the row follows the result, never the launch:
#   0   started   the lane record state/<task>.meta is there (an exit 0 with no lane record is a failed start);
#   75  deferred  the spawn said wait (pool full, no copy, load, capacity, a locked task set): a delayed check starts it AGAIN
#               under the same approval, as the next attempt, with no lead turn and no new approval. The delay is
#               JG_DISPATCH_RETRY_DELAY seconds (default 20; 0 turns the retry off and leaves it to the next beat), doubled for
#               each deferred attempt of the ticket before it in a row, never over 160; one retry waits for the whole home
#               (data/auto-dispatch/.retry-pending holds its due epoch), and it tries every deferred ticket;
#   else failed   the spawn's last line is the cause: named to the lead once, and not tried again until a new approval.
# Before a launch the check asks the ready state again: a lane record already there means the ticket is running (no spawn), and a
# start record of the ticket without a result is a start in flight (no second spawn). Each attempt is claimed by creating its
# record with noclobber, so two check runs, or a restart, start a ticket once. A start whose wrapper left no result in 10
# minutes is read from the lane record: there is one, it started; there is none, it failed.
# core/machines/tables/dispatch-start.tsv is the table of these states (ready, starting, started, deferred, refused);
# `dispatch.sh state <jg-home> <id>` is its observer.
# The lane target, the quota gates and the brief gates stay: the spawn applies its own and may refuse.
# The check runs one pass at a time per home: it holds the lock directory data/auto-dispatch/.check.lock (the holder's pid in it;
# a dead holder's lock is taken over). A call that finds a pass running leaves the mark data/auto-dispatch/.check.again FIRST,
# tries the lock once more, and else exits 0 printing nothing; the holder releases the lock after each pass, and when the mark is
# there takes the lock again, removes the mark and makes one more pass (at most 3 passes in one call; a mark left after the
# third starts one detached check, so it is never left for the next beat). So any number of events may start the check at once.
# A detached check (a retry, or that last one) prints nothing, so it names no ticket to the lead and raises no alert: the next
# beat does, from the same rows.
# Switch on, the check prints ONE line a beat when a ticket newly needs the lead (no approval record, no brief, no route, no
# delivery contract, a failed start); the line wakes the lead, and data/auto-dispatch/told.tsv keeps a ticket from being named twice for the same reason.
# Output: the one file data/auto-dispatch/rows.tsv, one row per verdict CHANGE of a ticket:
#   <epoch><TAB><id><TAB>would start|skipped|starting|started|deferred|spawn failed<TAB><route, or why>
# A beat that finds every ticket with the same verdict as its last row writes nothing. Watch only, the check prints nothing,
# so it wakes no one.
# Every pass also appends one line to data/auto-dispatch/passes.tsv (the last 5000 lines are kept), whatever its verdicts were:
#   <epoch><TAB>pass<TAB><candidates><TAB><started><TAB><deferred><TAB><seconds><TAB><switch on|off>
# candidates are the tickets the pass judged, started the ones it launched, deferred the ones the spawn told to wait; a pass that
# could not read the store writes no line. The watcher starts the check every minute (bin/jg-watch.sh, JG_DISPATCH_INTERVAL).
# Switch on, a ticket that passed all six reasons and still has no running start 10 minutes after its refusal (a brief with no
# delivery contract, an unreadable yolo posture, a failed start) raises the `ready-idle` alert through bin/jg-alert.sh, the
# alert table's own timer and rung, printed as the check's wake line; a start that takes resolves it. Watch only raises nothing.
# JG_AUTO_DISPATCH_BACKLOG, _HOLD, _SPAWN, _ALERT and _PROJECT_MODE name the backlog, captain-hold, spawn and project-mode commands
# (and JG_AUTO_DISPATCH_IN_FLIGHT the 600 seconds a start may take); tests point them at stand-ins, and
# JG_DISPATCH_TEST_RELEASE_DELAY (seconds, default none) holds the lock that long before a pass's release.
set -u
case "${1:-}" in
  check|pass) [ "$#" -eq 2 ] ;;
  state) [ "$#" -eq 3 ] ;;
  run) [ "$#" -ge 6 ] ;;
  *) false ;;
esac && [ -d "$2/state" ] || { echo "usage: dispatch.sh check <jg-home> | pass <jg-home> | state <jg-home> <id> | run <jg-home> <record> <task> <log> <spawn command...>" >&2; exit 2; }
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
PASSES=$DATA/auto-dispatch/passes.tsv
CHECK_LOCK=$DATA/auto-dispatch/.check.lock
CHECK_AGAIN=$DATA/auto-dispatch/.check.again
RETRY_PENDING=$DATA/auto-dispatch/.retry-pending
RETRY_DELAY=${JG_DISPATCH_RETRY_DELAY:-20}
MAX_PASSES=3
LOCK_HELD=0
QUIET=${JG_DISPATCH_DETACHED:-}   # set by detach: this check has no reader, so it keeps the lead's note and the alert for a beat
case "$RETRY_DELAY" in ''|*[!0-9]*) RETRY_DELAY=20 ;; esac
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

# verdict <id>: sets VERDICT to "route<TAB>..." when the ticket passes reasons 1 to 5, else "why<TAB>...".
VERDICT=
verdict() {
  local id=$1 route
  if [ -z "${APPROVED_EXISTS[$id]+x}" ]; then VERDICT=$'why\tno approval record'; return; fi
  if [ "$decisions_read" -eq 0 ]; then VERDICT=$'why\tits open decisions could not be read'; return; fi
  if [ -n "${BLOCKED_SET[$id]+x}" ]; then VERDICT=$'why\tan open decision is linked to it'; return; fi
  if [ -z "${SPAWNABLE_PROJECT[$id]+x}" ]; then
    VERDICT="why"$'\t'"not spawnable now (held, taken, closed, or not this home's project)"; return
  fi
  [ -s "$DATA/$id/brief.md" ] || { VERDICT=$'why\tno brief'; return; }
  route="${APPROVED_HARNESS[$id]:-} ${APPROVED_MODEL[$id]:-} ${APPROVED_EFFORT[$id]:-}"
  case "$route" in ' '*|*'  '*|*' ') VERDICT=$'why\tthe approval record has no route'; return ;; esac
  VERDICT="route"$'\t'"$route"
}

# Cache the dispatch preflight result for this pass. The spawn checks capacity again before leasing a copy.
pool_has_copy() {
  local project=$1 admit_err
  if [ -z "${POOL_WAIT_REASON[$project]+x}" ]; then
    POOL_WAIT_REASON[$project]=
    if [ -x "$RESERVE" ] && ! admit_err=$("$RESERVE" admit "$FMH" "$FMH/projects/$project" 2>&1 >/dev/null); then
      case "$admit_err" in
        *"cannot be counted"*) POOL_WAIT_REASON[$project]="copy count unknown (the pool could not be read; the next beat retries)" ;;
        *) POOL_WAIT_REASON[$project]="no free copy (the copies left are kept for a red fix)" ;;
      esac
    fi
  fi
  [ -z "${POOL_WAIT_REASON[$project]}" ]
}

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
declare -A APPROVED_AT=()
START_STATE=ready; START_WHY=
start_state() {
  local id=$1 f n best=0 rec result='' task='' launched='' approved='' reason='' current='' line
  START_STATE=ready; START_WHY=
  for f in "$START_PREFIX/$id".start.*; do
    [ -f "$f" ] || continue
    n=${f##*.start.}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -le "$best" ] || best=$n
  done
  [ "$best" -gt 0 ] || return 0
  rec=$START_PREFIX/$id.start.$best
  [ -f "$rec" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      task=*) task=${line#task=} ;;
      result=*) result=${line#result=} ;;
      launched-at=*) launched=${line#launched-at=} ;;
      approved-at=*) approved=${line#approved-at=} ;;
      reason=*) reason=${line#reason=} ;;
    esac
  done < "$rec"
  if [ -z "$result" ]; then
    # No result yet: the wrapper is still running the spawn, or it died. The lane record settles a dead wrapper.
    if [ $((now - ${launched:-0})) -lt "$IN_FLIGHT_SECONDS" ]; then START_STATE=starting
    elif lane_record "$task"; then START_STATE=started
    else START_STATE=refused; START_WHY="the start left no result in $IN_FLIGHT_SECONDS seconds (see data/auto-dispatch/$id.log)"; fi
    return 0
  fi
  # A result belongs to the approval it was started under; a newer approval starts over.
  if [ -n "${APPROVED_AT[$id]+x}" ]; then current=${APPROVED_AT[$id]}
  else current=$(approved_field "$id" approved-at); fi
  if [ "${current:-0}" -gt "${approved:-0}" ] 2>/dev/null; then return 0; fi
  START_STATE=$result; START_WHY=$reason
}

# last_line <log>: the last line of the spawn's output as one short line with no tab.
last_line() { grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | tr '\t\r' '  ' | cut -c1-200; }

# detach <command...>: run it in its own session, with no input and no output, and return at once.
detach() {
  if command -v setsid >/dev/null 2>&1; then ( env JG_DISPATCH_DETACHED=1 setsid nohup "$@" > /dev/null 2>&1 < /dev/null & ) 2>/dev/null
  else ( env JG_DISPATCH_DETACHED=1 nohup "$@" > /dev/null 2>&1 < /dev/null & ) 2>/dev/null; fi
}

# retry_delay <id> <attempt>: the seconds to wait before the retry of a deferred attempt: the base delay, doubled for each attempt
# before it in a row that was deferred too (the start records hold the last three), never over 160.
retry_delay() {
  local id=$1 delay=$RETRY_DELAY n=$(($2 - 1))
  while [ "$n" -ge 1 ] && [ "$delay" -lt 160 ] && [ "$(start_field "$START_PREFIX/$id.start.$n" result)" = deferred ]; do
    delay=$((delay * 2)); n=$((n - 1))
  done
  [ "$delay" -le 160 ] && echo "$delay" || echo 160
}

# schedule_retry <record>: one delayed check for the home. The mark holds its due epoch and is created with noclobber, so the second
# deferral of a pass leaves the first one's retry alone; the delayed check removes the mark before it runs, and a mark more than a
# minute overdue belongs to a retry that died (a restart), so it is replaced.
schedule_retry() {
  local base=${1##*/} id attempt delay now pending
  [ "$RETRY_DELAY" -gt 0 ] || return 0
  id=${base%.start.*}; attempt=${base##*.start.}
  now=$(date +%s)
  pending=$(cat "$RETRY_PENDING" 2>/dev/null)
  case "$pending" in ''|*[!0-9]*) ;; *) [ $((now - pending)) -gt 60 ] && rm -f -- "$RETRY_PENDING" ;; esac
  delay=$(retry_delay "$id" "$attempt")
  ( set -C; printf '%s\n' $((now + delay)) > "$RETRY_PENDING" ) 2>/dev/null || return 0
  # shellcheck disable=SC2016  # the delayed shell expands its own arguments
  detach bash -c 'sleep "$1"; rm -f -- "$2"; exec bash "$3" check "$4"' _ "$delay" "$RETRY_PENDING" "$SELF" "$FMH"
}

# run_start <record> <task> <log> <spawn command...>: the detached wrapper of one start. It runs the spawn and writes what the
# spawn really did into the record: the exit 0 with the lane record there is `started`, the exit 75 is `deferred` (the spawn
# said wait; a delayed check starts it again), anything else is `refused` with the spawn's last line as its cause.
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
  [ "$result" != deferred ] || schedule_retry "$rec"
}

# The line every `bin/jg-brief.sh <task> <repo> --scout` brief carries and no ship brief carries (bin/jg-dispatch-resolve.sh reads it too).
RECON_BRIEF_LINE='This is a SCOUT task: the deliverable is a written report, not a PR.'

# launch <id> <project> <route>: claim the next attempt for the ticket and spawn it detached through `run_start`. Prints
# "starting" and returns 0, or prints why it cannot be tried and returns 1. A claim another run won is a start in flight.
launch() {
  local id=$1 project=$2 route=$3 brief=$DATA/$1/brief.md mode yolo branch task harness model effort attempt rec
  local -a lane=()
  task=${id//./-}
  if grep -qxF "$RECON_BRIEF_LINE" "$brief"; then
    lane=(--scout)
  else
    mode=$(sed -n 's/^Delivery contract: mode=\([A-Za-z-]*\).*$/\1/p' "$brief" | head -n 1)
    [ -n "$mode" ] || { echo "the brief has no delivery contract line"; return 1; }
    yolo=$("$PROJECT_MODE" "$project" 2>/dev/null | awk '{ print $2 }')
    case "$yolo" in on|off) ;; *) echo "the project's registered yolo posture could not be read"; return 1 ;; esac
    lane=(--mode "$mode" --yolo "$yolo")
    # shellcheck disable=SC2016  # the backquotes are the brief's own text
    branch=$(sed -n 's/^1\. First action: create your branch: `git checkout -b \([^ ]*\) --`.*$/\1/p' "$brief" | head -n 1)
    case "$branch" in *"$task") lane+=(--branch-prefix "${branch%"$task"}") ;; esac
  fi
  read -r harness model effort <<< "$route"
  attempt=$(( $(latest_attempt "$id") + 1 )); rec=$START_PREFIX/$id.start.$attempt
  # One create claims the attempt: a second run, or a restart, that reads the same count loses here and starts nothing.
  if ! ( set -C; printf 'attempt=%s\ntask=%s\napproved-at=%s\nlaunched-at=%s\nroute=%s\n' \
      "$attempt" "$task" "$(approved_field "$id" approved-at)" "$now" "$route" > "$rec" ) 2>/dev/null; then echo starting; return 0; fi
  rm -f "$START_PREFIX/$id.start.$((attempt - 3))"   # a deferral retried each beat keeps its last three attempts, not all of them
  ( setsid nohup bash "$SELF" run "$FMH" "$rec" "$task" "$DATA/auto-dispatch/$id.log" \
      "$SPAWN" "$task" "$FMH/projects/$project" --ticket "$id" "${lane[@]}" \
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

# take_lock: claim the check lock, a directory whose one `mkdir` is the atomic step; the holder's pid is written into it. Returns 1
# while a live pass holds it. A lock whose pid is dead (or that never got one, and is over a minute old) is moved aside, which one
# taker wins, and claimed again.
take_lock() {
  local pid moved stale=$CHECK_LOCK.stale.$$
  claim_lock && return 0
  pid=$(cat "$CHECK_LOCK/pid" 2>/dev/null)
  case "$pid" in
    '') [ -n "$(find "$CHECK_LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 1 ;;
    *[!0-9]*) ;;
    *) ! kill -0 "$pid" 2>/dev/null || return 1 ;;
  esac
  mv "$CHECK_LOCK" "$stale" 2>/dev/null || return 1
  moved=$(cat "$stale/pid" 2>/dev/null)
  if [ "$moved" != "$pid" ]; then mv "$stale" "$CHECK_LOCK" 2>/dev/null; return 1; fi   # it was a live holder's fresh lock: give it back
  rm -f -- "$stale/pid"; rmdir "$stale" 2>/dev/null
  claim_lock
}
claim_lock() { mkdir "$CHECK_LOCK" 2>/dev/null || return 1; printf '%s\n' "$$" > "$CHECK_LOCK/pid"; LOCK_HELD=1; }

# release_lock [hook]: give the lock back. `hook` holds it first for JG_DISPATCH_TEST_RELEASE_DELAY seconds, so a test can place a
# call in the gap between a pass's end and its release.
release_lock() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  [ "${1:-}" != hook ] || [ -z "${JG_DISPATCH_TEST_RELEASE_DELAY:-}" ] || sleep "$JG_DISPATCH_TEST_RELEASE_DELAY"
  rm -f -- "$CHECK_LOCK/pid"; rmdir "$CHECK_LOCK" 2>/dev/null
  LOCK_HELD=0
}

# check_call: one call of the check. The order is what keeps a mark from being lost: a caller that cannot take the lock writes the
# mark BEFORE it tries once more, and the holder releases BEFORE it reads the mark. The holder takes the lock again before it
# removes the mark, so two passes never overlap, and a mark made before a pass starts is covered by that pass.
check_call() {
  local passes=0
  if ! take_lock; then
    : > "$CHECK_AGAIN"
    take_lock || return 0
  fi
  trap release_lock EXIT
  while :; do
    rm -f -- "$CHECK_AGAIN"
    bash "$SELF" pass "$FMH"
    passes=$((passes + 1))
    release_lock hook
    [ -e "$CHECK_AGAIN" ] || return 0
    if [ "$passes" -ge "$MAX_PASSES" ]; then detach bash "$SELF" check "$FMH"; return 0; fi   # the cap bounds this call, never leaves a mark for the next beat
    take_lock || return 0   # another pass took it after our release: it starts after the mark, so it covers it
  done
}

case "$1" in
  check) check_call; exit 0 ;;
  pass) ;;
  run) shift 2; run_start "$@"; exit $? ;;
  state) now=$(date +%s); [ -f "$APPROVED/$3" ] || exit 0; start_state "$3"; echo "$START_STATE"; exit 0 ;;
esac

tmp=$(mktemp -d) || exit 0
trap 'rm -rf -- "$tmp"' EXIT
SPAWNABLE_IDS=$tmp/spawnable
"$BACKLOG" ready --spawnable > "$tmp/out" 2>/dev/null || exit 0   # the store could not answer: write nothing this beat
declare -A SPAWNABLE_PROJECT=() APPROVED_EXISTS=() APPROVED_AT=() APPROVED_HARNESS=() APPROVED_MODEL=() APPROVED_EFFORT=()
: > "$SPAWNABLE_IDS"
while IFS=$'\t' read -r sid sproj _rest; do
  [ -n "$sid" ] && [ -n "$sproj" ] || continue
  printf '%s\n' "$sid" >> "$SPAWNABLE_IDS"
  [ -n "${SPAWNABLE_PROJECT[$sid]+x}" ] || SPAWNABLE_PROJECT[$sid]=$sproj
done < "$tmp/out"
: > "$tmp/approved-raw"; : > "$tmp/approved-pairs"
for f in "$APPROVED"/*; do
  [ -f "$f" ] || continue
  id=${f##*/}
  APPROVED_EXISTS[$id]=1
  printf '%s\n' "$id" >> "$tmp/approved-raw"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      approved-at=*) APPROVED_AT[$id]=${line#approved-at=} ;;
      harness=*)     APPROVED_HARNESS[$id]=${line#harness=} ;;
      model=*)       APPROVED_MODEL[$id]=${line#model=} ;;
      effort=*)      APPROVED_EFFORT[$id]=${line#effort=} ;;
    esac
  done < "$f"
  printf '%s\t%s\n' "$id" "${APPROVED_AT[$id]:-}" >> "$tmp/approved-pairs"
done
sort -u "$tmp/approved-raw" > "$tmp/approved"
# The item store (core/item-store) is also told of each approval record: one dispatch item held by the lead until a spawn closes it.
# Guarded by the home's own switch, silent, and never a reason to change this check's output or exit; today's record decides.
if [ -e "$FMH/config/item-store" ] && [ -s "$tmp/approved-pairs" ]; then
  ROOT=$(cd "$(dirname "$SELF")/../.." && pwd -P)
  adapter=$ROOT/core/item-store/adapters/dispatch.py
  [ -f "$adapter" ] || adapter=$FMH/core/item-store/adapters/dispatch.py
  [ ! -f "$adapter" ] || python3 -I "$adapter" approve-batch < "$tmp/approved-pairs" >/dev/null 2>&1 || true
fi

# One decision read for all approved candidates. Only a successful batch with the expected header can clear a candidate.
decisions_read=0
declare -A BLOCKED_SET=()
if [ -s "$tmp/approved" ] && "$HOLD" blocking --batch < "$tmp/approved" > "$tmp/block-out" 2>/dev/null; then
  {
    if IFS= read -r header && [ "$header" = "blocking-batch: ok" ]; then
      decisions_read=1
      while IFS=$'\t' read -r bid _rest; do
        [ -n "$bid" ] && BLOCKED_SET[$bid]=1
      done
    fi
  } < "$tmp/block-out"
fi

[ ! -x "$SCALE" ] || "$SCALE" check "$FMH" >/dev/null 2>&1   # the lane limit takes its tick on this beat
free=$(free_lanes)
now=$(date +%s)
started=0; launched=0; deferred=0
ACT=0; ! switch_on || ACT=1
: > "$tmp/lead"; : > "$tmp/alerts"
# List order is the store's priority order and is kept as it is (no sort); approved tickets the list lacks come last, and they never start.
awk '!seen[$0]++' "$SPAWNABLE_IDS" "$tmp/approved" > "$tmp/ordered"
declare -A LAST_EPOCH=() LAST_VERDICT=() POOL_WAIT_REASON=()
if [ -s "$ROWS" ]; then
  while IFS=$'\t' read -r r_epoch r_id r_kind r_detail; do
    [ -n "$r_id" ] || continue
    LAST_EPOCH[$r_id]=$r_epoch
    LAST_VERDICT[$r_id]=$r_kind$'\t'$r_detail
  done < <(awk -F'\t' 'NF >= 4 { e[$2] = $1; k[$2] = $3; d[$2] = $4 } END { for (id in e) printf "%s\t%s\t%s\t%s\n", e[id], id, k[id], d[id] }' "$ROWS" 2>/dev/null)
fi
# record_row <id> <idle 0|1> <kind> <detail>: write the ticket's row when its verdict changed, and do what the row asks: a row the
# check may not leave raises ready-idle, a started row clears the alert and the lead's note, a row the lead must clear is named once.
record_row() {
  local id=$1 idle=$2 row=$3$'\t'$4 since prev_v=${LAST_VERDICT[$1]:-}
  since=$now; [ "$prev_v" != "$row" ] || since=${LAST_EPOCH[$id]:-$now}
  if [ "$prev_v" != "$row" ]; then
    printf '%s\t%s\t%s\n' "$now" "$id" "$row" >> "$ROWS"
    LAST_EPOCH[$id]=$now
    LAST_VERDICT[$id]=$row
  fi
  if [ "$ACT" -eq 1 ] && [ "$idle" -eq 1 ] && [ -z "$QUIET" ]; then ready_idle "$id" "$since"; fi
  case "$row" in
    started$'\t'*)
      if [ "$prev_v" != "$row" ] || [ -f "$STATE/alerts/ready-idle--$id.rec" ]; then
        JG_STATE_OVERRIDE=$STATE "$ALERT" resolve "ready-idle--$id" --proof source:row-started >/dev/null 2>&1
      fi
      if [ -s "$TOLD" ] && grep -q -F -- "$id"$'\t' "$TOLD" 2>/dev/null; then
        grep -v -F -- "$id"$'\t' "$TOLD" > "$tmp/told" 2>/dev/null; cat "$tmp/told" > "$TOLD" 2>/dev/null
      fi ;;
  esac
  if [ "$ACT" -eq 1 ] && [ -z "$QUIET" ] && needs_lead "${row%%$'\t'*}" "${row#*$'\t'}" && ! grep -qxF -- "$id"$'\t'"$row" "$TOLD" 2>/dev/null; then
    printf '%s\t%s\n' "$id" "$row" >> "$TOLD"; printf '%s (%s)\n' "$id" "${row#*$'\t'}" >> "$tmp/lead"
  fi
}

# route_of <id>: the route of the id's approval record.
route_of() { printf '%s %s %s' "${APPROVED_HARNESS[$1]:-}" "${APPROVED_MODEL[$1]:-}" "${APPROVED_EFFORT[$1]:-}"; }

while IFS= read -r id; do
  [ -n "$id" ] || continue
  verdict "$id"
  v=$VERDICT
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
      elif ! pool_has_copy "${SPAWNABLE_PROJECT[$id]}"; then
        detail=${POOL_WAIT_REASON[${SPAWNABLE_PROJECT[$id]}]}
        waits=1
      elif detail=$(launch "$id" "${SPAWNABLE_PROJECT[$id]}" "${v#route$'\t'}"); then
        started=$((started + 1)); launched=$((launched + 1)); kind=starting; detail=${v#route$'\t'}
      else idle=1; fi ;;
    *) detail=${v#why$'\t'} ;;
  esac
  [ "$START_STATE" != deferred ] || [ "$kind" = starting ] || deferred=$((deferred + 1))
  # A deferred ticket that waits for a lane or a copy keeps its deferred row; the wait is not a new verdict.
  [ "$START_STATE" != deferred ] || [ "$waits" -eq 0 ] || continue
  record_row "$id" "$idle" "$kind" "$detail"
done < "$tmp/ordered"
cat "$tmp/alerts"
# The pass's own line: the watcher starts this check every minute, and this file is the record that it ran.
{ printf '%s\tpass\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(grep -c . "$tmp/ordered")" "$launched" "$deferred" "$SECONDS" "$([ "$ACT" -eq 1 ] && echo on || echo off)" >> "$PASSES"
  [ "$(wc -l < "$PASSES")" -le 5000 ] || { tail -n 5000 "$PASSES" > "$PASSES.tmp.$$" && mv -f "$PASSES.tmp.$$" "$PASSES"; }; } 2>/dev/null
[ "$ACT" -eq 0 ] || [ ! -s "$tmp/lead" ] || printf 'auto-dispatch: lead, these tickets are not started by themselves: %s\n' "$(paste -sd';' "$tmp/lead" | sed 's/;/; /g')"
exit 0
