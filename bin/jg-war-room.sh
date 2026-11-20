#!/usr/bin/env bash
# jg-war-room.sh - start a /war-room's variant Recons together: one ticket, one brief and one live lane for each angle.
#
# Usage: jg-war-room.sh start <council-ticket> --project <name> --angles <a,b,c> --depth <standard|deep>
#                       --harness <h> --model <m> --effort <e>
#        jg-war-room.sh --help
#
# For each angle, in the order given:
#   1. Ticket: the child of the council titled `<angle> variant Recon`, found by that exact title; when the council has none, one
#      is filed with the sections strict intake asks for. A second run never files a second one.
#   2. Brief: `bin/jg-brief.sh <task> <project> --scout --depth <depth> --ticket <row>`, its task part filled with the angle and
#      the three spec lines of the skill's "Each Recon's spec" (the handoff draft and revise, the hold and complete, round 3).
#      A brief that holds `Angle: <angle>` and the depth is kept as it is.
#   3. Start: every lane that has no live task record is started at the same moment, one `bin/jg-spawn.sh <task> <project dir>
#      --ticket <row> --scout --harness <h> --model <m> --effort <e>` for each lane in the background (a scout takes no --mode
#      or --yolo), and the command waits up to 300 s (JG_WAR_ROOM_WAIT) for each to have a task record or an exit code.
# It prints one line for each angle, in the order given:
#   <angle>: <task> live                     the spawn left the lane's task record
#   <angle>: <task> already live             the lane had a task record before this run; nothing was started
#   <angle>: <task> not started: <reason>    the spawn's last line (an exit of 75 is a wait: run the command again)
#   <angle>: not started: <reason>           no ticket or brief could be made
# Exit 0 when every lane is live, 1 otherwise. Exit 2 for usage, an unknown council, depth or project, with nothing written.
# JG_WAR_ROOM_SPAWN names the spawn command; tests point it at a stand-in.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
PROJECTS="${JG_PROJECTS_OVERRIDE:-$JG_HOME/projects}"
SPAWN=${JG_WAR_ROOM_SPAWN:-$SCRIPT_DIR/jg-spawn.sh}
WAIT=${JG_WAR_ROOM_WAIT:-300}
# shellcheck source=bin/jg-backlog-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-backlog-lib.sh"
export JG_HOME

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
refuse() { printf 'jg-war-room: %s\n' "$*" >&2; exit 2; }

[ "${1:-}" != -h ] && [ "${1:-}" != --help ] || { usage; exit 0; }
[ "${1:-}" = start ] || refuse "usage: jg-war-room.sh start <council-ticket> --project <name> --angles <a,b,c> --depth <standard|deep> --harness <h> --model <m> --effort <e>"
shift
COUNCIL='' PROJECT='' ANGLES='' DEPTH='' HARNESS='' MODEL='' EFFORT=''
while [ $# -gt 0 ]; do
  case $1 in
    --project|--angles|--depth|--harness|--model|--effort)
      [ $# -ge 2 ] || refuse "$1 needs a value"
      case $1 in
        --project) PROJECT=$2 ;; --angles) ANGLES=$2 ;; --depth) DEPTH=$2 ;;
        --harness) HARNESS=$2 ;; --model) MODEL=$2 ;; --effort) EFFORT=$2 ;;
      esac
      shift ;;
    -*) refuse "unknown flag $1" ;;
    *) [ -z "$COUNCIL" ] || refuse "one council ticket only"; COUNCIL=$1 ;;
  esac
  shift
done
[ -n "$COUNCIL" ] || refuse "the council ticket is missing"
for need in PROJECT ANGLES DEPTH HARNESS MODEL EFFORT; do
  [ -n "${!need}" ] || refuse "--$(printf '%s' "$need" | tr '[:upper:]' '[:lower:]') is missing"
done
case $DEPTH in standard|deep) ;; *) refuse "--depth is standard or deep (got '$DEPTH')" ;; esac
case $WAIT in ''|*[!0-9]*) refuse "JG_WAR_ROOM_WAIT is a whole number of seconds" ;; esac
PROJECT_DIR=$PROJECTS/$PROJECT
[ -d "$PROJECT_DIR" ] || refuse "no project $PROJECT: $PROJECT_DIR is not a directory"

backlog() { "$SCRIPT_DIR/jg-backlog.sh" "$@"; }
bd_() { python3 -I "$SCRIPT_DIR/../core/item-store/adapters/bd_compat.py" "$@"; }
COUNCIL_SHOW=$(backlog show "$COUNCIL" 2>&1) || refuse "council ticket $COUNCIL: $(printf '%s\n' "$COUNCIL_SHOW" | head -1)"
COUNCIL_TITLE=$(printf '%s\n' "$COUNCIL_SHOW" | sed -n 's/^  title: *//p' | head -1)
COUNCIL_TITLE=${COUNCIL_TITLE#\"}; COUNCIL_TITLE=${COUNCIL_TITLE%\"}

# The ticket of an angle: the council's child with exactly this title, else a new one.
child_titled() {  # <title>
  bd_ list --parent "$COUNCIL" --all --limit 0 --json 2>/dev/null \
    | jq -r --arg t "$1" '[.[]? | select(.title == $t) | .id] | sort | first // empty'
}
file_child() {  # <angle> <title>: prints the new row's id, or the refusal on stderr
  local angle=$1 title=$2 body made
  body=$(printf '## Captain\nWar room %s (%s) asks for independent Recons from different angles.\n## Ask\nRun the %s variant Recon of council %s and write its report.\n## Why\nOne angle each keeps the variants independent, so the synthesis can compare them.\n## Done when\nThe report passes bin/jg-recon-gate.sh and its critic has closed every gap.\n## Acceptance Criteria\nThe report answers the council ticket from the %s angle with its evidence.' \
    "$COUNCIL" "$COUNCIL_TITLE" "$angle" "$COUNCIL" "$angle")
  made=$(backlog add --parent "$COUNCIL" "$title" --repo "$PROJECT" --priority 2 --body "$body" --json 2>&1) \
    || { printf '%s\n' "$made" | grep -v '^[[:space:]]*$' | tail -n 1 >&2; return 1; }
  jq -r '.task.id // .id // empty' <<< "$made" 2>/dev/null
}

# live_record <task>: the task's published task record (one that only keeps a failed launch's copy is not one).
live_record() { [ -f "$STATE/$1.meta" ] && ! grep -q '^cleanup_recovery=' "$STATE/$1.meta" 2>/dev/null; }
last_line() { grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | tr '\t\r' '  ' | cut -c1-200; }

# shellcheck disable=SC2016  # the backquotes are the brief's own text
spec_fill() {  # <angle> <task>
  printf 'Angle: %s\nRun `%s/bin/jg-recon-handoff.sh draft %s` before your done line and `%s/bin/jg-recon-handoff.sh revise %s` after you fix a round'"'"'s gaps.\nYou may run `%s/bin/jg-captain-hold.sh hold` and `complete` for this task'"'"'s own decisions (captain-hold-lifecycle). Write no other backlog item.\nRound 3 is the last round that may report gaps. A gap you cannot close in one revision moves to section 7 or 10 with its reason, and the critic closes it as carried.' \
    "$1" "$JG_ROOT" "$2" "$JG_ROOT" "$2" "$JG_ROOT"
}
# shellcheck disable=SC2016  # the backquotes are the brief's own text
task_fill() {  # <angle>
  printf 'War room council %s (%s): run the %s variant Recon of it. The council ticket holds the problem in full: read it with `%s/bin/jg-backlog.sh show %s --full`.' \
    "$COUNCIL" "$COUNCIL_TITLE" "$1" "$JG_ROOT" "$COUNCIL"
}

# write_brief <angle> <task> <row>: prints why it could not, returns 1.
write_brief() {
  local angle=$1 task=$2 row=$3 brief=$DATA/$2/brief.md t p
  if [ -e "$brief" ]; then
    if grep -qxF "Angle: $angle" "$brief" && grep -qxF "Recon depth: $DEPTH" "$brief" && ! grep -qE '\{TASK\}|\{JUGGERNAUT_SPEC\}' "$brief"; then
      return 0
    fi
    echo "a different brief is already at $brief"; return 1
  fi
  "$SCRIPT_DIR/jg-brief.sh" "$task" "$PROJECT" --scout --depth "$DEPTH" --ticket "$row" >/dev/null 2>"$RUN/.brief.err" \
    || { echo "the brief was not written: $(last_line "$RUN/.brief.err")"; rm -f "$RUN/.brief.err"; return 1; }
  rm -f "$RUN/.brief.err"
  t=$(task_fill "$angle") p=$(spec_fill "$angle" "$task")
  TASK_FILL=$t SPEC_FILL=$p awk '
    BEGIN { t = ENVIRON["TASK_FILL"]; p = ENVIRON["SPEC_FILL"] }
    $0 == "{TASK}" { print t; next }
    $0 == "{JUGGERNAUT_SPEC}" { print p; next }
    { print }' "$brief" > "$brief.tmp"
  mv "$brief.tmp" "$brief" || { echo "the brief of $row could not be filled"; return 1; }
  ! grep -qE '\{TASK\}|\{JUGGERNAUT_SPEC\}' "$brief" || { echo "the brief of $row still holds a placeholder"; return 1; }
}

# Each lane's spawn output and exit code stay in data/war-room/<council>/, so a lane that is still starting when this ends has its say.
RUN=$DATA/war-room/$COUNCIL
mkdir -p "$RUN" || refuse "cannot write $RUN"

# --- Tickets and briefs, then every start at the same moment ----------------------------------------------------
LANES=()   # angle<TAB>task<TAB>state (live, start, or a refusal text)
IFS=',' read -ra ANGLE_LIST <<< "$ANGLES"
for raw in "${ANGLE_LIST[@]}"; do
  angle=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$angle" ] || continue
  title="$angle variant Recon"
  row=$(child_titled "$title")
  if [ -z "$row" ]; then
    row=$(file_child "$angle" "$title" 2>"$RUN/.file.err") && [ -n "$row" ] \
      || { LANES+=("$angle"$'\t'-$'\t'"the ticket was not filed: $(last_line "$RUN/.file.err")"); continue; }
  fi
  task=$(jg_backlog_task_id "$row" "$MODEL")
  if live_record "$task"; then LANES+=("$angle"$'\t'"$task"$'\t'live); continue; fi
  why=$(write_brief "$angle" "$task" "$row") || { LANES+=("$angle"$'\t'"$task"$'\t'"$why"); continue; }
  # The lane starts now, in its own session, so it outlives this command when it waits for a copy; its exit code is its answer.
  rm -f "$RUN/$task.rc"
  # shellcheck disable=SC2016  # the shell of the lane expands its own arguments
  setsid nohup bash -c '"$@" > "$0.log" 2>&1 < /dev/null; echo $? > "$0.rc.tmp" && mv "$0.rc.tmp" "$0.rc"' "$RUN/$task" \
    "$SPAWN" "$task" "$PROJECT_DIR" --ticket "$row" --scout --harness "$HARNESS" --model "$MODEL" --effort "$EFFORT" \
    > /dev/null 2>&1 < /dev/null &
  LANES+=("$angle"$'\t'"$task"$'\t'start)
done

# --- Wait for each lane's record or exit code, and report --------------------------------------------------------
STATUS=0
for lane in "${LANES[@]}"; do
  IFS=$'\t' read -r angle task state <<< "$lane"
  case $state in
    live) printf '%s: %s already live\n' "$angle" "$task"; continue ;;
    start) ;;
    *) if [ "$task" = - ]; then printf '%s: not started: %s\n' "$angle" "$state"
       else printf '%s: %s not started: %s\n' "$angle" "$task" "$state"; fi
       STATUS=1; continue ;;
  esac
  waited=0
  while ! live_record "$task" && [ ! -f "$RUN/$task.rc" ] && [ "$waited" -lt "$WAIT" ]; do sleep 1; waited=$((waited + 1)); done
  rc=$(cat "$RUN/$task.rc" 2>/dev/null)
  if live_record "$task" && { [ -z "$rc" ] || [ "$rc" = 0 ]; }; then
    printf '%s: %s live\n' "$angle" "$task"
  else
    if [ -n "$rc" ]; then reason=$(last_line "$RUN/$task.log"); reason=${reason:-the spawn exited $rc with no output}
    else reason="no task record and no exit after $WAIT s (the spawn may still be running; its output is in $RUN/$task.log)"; fi
    printf '%s: %s not started: %s\n' "$angle" "$task" "$reason"
    STATUS=1
  fi
done
exit "$STATUS"
