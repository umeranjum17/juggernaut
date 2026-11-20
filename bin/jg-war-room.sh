#!/usr/bin/env bash
# jg-war-room.sh - run a /war-room: start its variant Recons together, move it by itself to the owner's plan approval, start /blitz.
#
# Usage: jg-war-room.sh start <council-ticket> --project <name> --angles <a,b,c> --depth <standard|deep>
#                       --harness <h> --model <m> --effort <e> [--synthesis-depth <standard|deep>] [--no-variant-critics]
#        jg-war-room.sh next <council-ticket>
#        jg-war-room.sh approve <council-ticket> --words <the owner's words> [--by <who>]
#        jg-war-room.sh --help
#
# start: for each angle, in the order given:
#   1. Ticket: the child of the council titled `<angle> variant Recon`, found by that exact title; when the council has none, one
#      is filed with the sections strict intake asks for. A second run never files a second one.
#   2. Brief: `bin/jg-brief.sh <task> <project> --scout --depth <depth> --ticket <row>`, its task part filled with the angle and
#      the three spec lines of the skill's "Each Recon's spec" (the handoff draft and revise, the hold and complete, round 3).
#      A brief that holds `Angle: <angle>` and the depth is kept as it is.
#   3. Start: every lane that has no live task record is started at the same moment, one `bin/jg-spawn.sh <task> <project dir>
#      --ticket <row> --scout --harness <h> --model <m> --effort <e>` for each lane in the background (a scout takes no --mode
#      or --yolo), and the command waits up to 300 s (JG_WAR_ROOM_WAIT) for each to have a task record or an exit code.
# --depth is the depth of the variants. --synthesis-depth is the depth of the synthesis Recon `next` starts later (default: --depth).
# --no-variant-critics makes `next` file no critic lane for a variant: that variant writes its own critic round (`Critic: self`, which
# the gate accepts at standard depth only) and the synthesis keeps its separate critic. /war-room fast is
# `--depth standard --synthesis-depth deep --no-variant-critics`; /war-room full is `--depth deep`.
# It also writes data/war-room/<council>/record (council, project, angles, depth, harness, model, effort, synthesis_depth,
# variant_critics), which `next` reads (a record without the last two is `--depth` for the synthesis and a critic for each variant), and it
# prints one line for each angle, in the order given:
#   <angle>: <task> live                     the spawn left the lane's task record
#   <angle>: <task> already live             the lane had a task record before this run; nothing was started
#   <angle>: <task> not started: <reason>    the spawn's last line (an exit of 75 is a wait: run the command again)
#   <angle>: not started: <reason>           no ticket or brief could be made
# Exit 0 when every lane is live, 1 otherwise. Exit 2 for usage, an unknown council, depth or project, or --no-variant-critics with
# deep variants, with nothing written.
#
# next: one idempotent step that does what is due and nothing else (one run at a time for a council; a second waits its turn).
# bin/jg-recon-handoff.sh starts it, detached, after each successful draft, revise or verdict of a council's lane
# (JG_WAR_ROOM_NEXT=0 turns that off); it can still be run by hand. Each lane below is filed as a child of the council, briefed
# the way `start` briefs one, and started once (a lane that has a task record, a status line or an exit code 0 is never started again):
#   a. a variant or the synthesis whose handoff phase is `drafted`: its critic, titled `<lane title> critic`, then
#      `bin/jg-recon-handoff.sh assign <lane> --critic <critic>` (a variant gets none when the record says variant_critics=0);
#   b. every variant passes bin/jg-recon-gate.sh: the synthesis Recon, with the three report paths;
#   c. the synthesis passes its gate: the dry run of order 1;
#   d. the dry run is done (its status line) and `bin/jg-swarm-plan-check.sh <synthesis>/orders/plan.json` passes: the council is held
#      once for the owner's plan approval (bin/jg-captain-hold.sh hold --must plan-approval; data/war-room/<council>/plan-asked
#      keeps the plan path) and the output says `owner approval asked`.
# One line for each step taken, then, when the owner was not just asked, one line for what it waits for: `waits: <lane> <phase>`.
# Exit 0, or 1 when a step was refused (its line says why). Exit 2 for usage, an unknown council or a council with no record.
#
# approve: Main runs it once it has read the owner's yes. It refuses until the owner was asked, records data/war-room/<council>/approved
# (who, when, the owner's words) and runs `bin/jg-swarm.sh start <plan.json>` with the harness, model and effort of the record. A second
# approve prints `already started`; one whose swarm start failed runs it again, and keeps the first record of the words.
# JG_WAR_ROOM_SPAWN, JG_WAR_ROOM_GATE and JG_WAR_ROOM_SWARM name the spawn, gate and swarm commands; tests point them at stand-ins.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
PROJECTS="${JG_PROJECTS_OVERRIDE:-$JG_HOME/projects}"
SPAWN=${JG_WAR_ROOM_SPAWN:-$SCRIPT_DIR/jg-spawn.sh}
GATE=${JG_WAR_ROOM_GATE:-$SCRIPT_DIR/jg-recon-gate.sh}
SWARM=${JG_WAR_ROOM_SWARM:-$SCRIPT_DIR/jg-swarm.sh}
HANDOFF=$SCRIPT_DIR/jg-recon-handoff.sh
WAIT=${JG_WAR_ROOM_WAIT:-300}
# shellcheck source=bin/jg-backlog-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-backlog-lib.sh"
export JG_HOME

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
refuse() { printf 'jg-war-room: %s\n' "$*" >&2; exit 2; }
USAGE="usage: jg-war-room.sh start <council-ticket> --project <name> --angles <a,b,c> --depth <standard|deep> --harness <h> --model <m> --effort <e>
                                   [--synthesis-depth <standard|deep>] [--no-variant-critics]
       jg-war-room.sh next <council-ticket>
       jg-war-room.sh approve <council-ticket> --words <the owner's words> [--by <who>]"

backlog() { "$SCRIPT_DIR/jg-backlog.sh" "$@"; }
bd_() { python3 -I "$SCRIPT_DIR/../core/item-store/adapters/bd_compat.py" "$@"; }

# --- The council and its lanes -----------------------------------------------------------------------------------
COUNCIL='' COUNCIL_TITLE='' RUN=''
PROJECT='' ANGLES='' DEPTH='' HARNESS='' MODEL='' EFFORT='' PROJECT_DIR='' SYNTH_DEPTH='' VARIANT_CRITICS=1

# open_council <council>: the ticket must exist; the files of its lanes live in data/war-room/<council>/.
open_council() {
  local show
  COUNCIL=$1
  show=$(backlog show "$COUNCIL" 2>&1) || refuse "council ticket $COUNCIL: $(printf '%s\n' "$show" | head -1)"
  COUNCIL_TITLE=$(printf '%s\n' "$show" | sed -n 's/^  title: *//p' | head -1)
  COUNCIL_TITLE=${COUNCIL_TITLE#\"}; COUNCIL_TITLE=${COUNCIL_TITLE%\"}
  RUN=$DATA/war-room/$COUNCIL
}

# The council's children, read once and again after one is filed.
CHILDREN=''
child_titled() {  # <title> -> the id of the council's child with exactly this title
  [ -n "$CHILDREN" ] || CHILDREN=$(bd_ list --parent "$COUNCIL" --all --limit 0 --json 2>/dev/null)
  jq -r --arg t "$1" '[.[]? | select(.title == $t) | .id] | sort | first // empty' <<< "$CHILDREN"
}
file_child() {  # <title> <ask> <done>: prints the new row's id, or the refusal on stderr
  local title=$1 body made
  body=$(printf '## Captain\nWar room %s (%s) asks for independent Recons from different angles.\n## Ask\n%s\n## Why\nOne lane for each step keeps the variants independent, so the synthesis can compare them.\n## Done when\n%s\n## Acceptance Criteria\n%s' \
    "$COUNCIL" "$COUNCIL_TITLE" "$2" "$3" "$3")
  made=$(backlog add --parent "$COUNCIL" "$title" --repo "$PROJECT" --priority 2 --body "$body" --json 2>&1) \
    || { printf '%s\n' "$made" | grep -v '^[[:space:]]*$' | tail -n 1 >&2; return 1; }
  jq -r '.task.id // .id // empty' <<< "$made" 2>/dev/null
}
lane_row() {  # <title> <ask> <done>: the child with this title, else a new one; prints the row, or the refusal on stderr
  local row
  row=$(child_titled "$1")
  [ -z "$row" ] || { printf '%s\n' "$row"; return 0; }
  file_child "$1" "$2" "$3" || return 1
}
task_of() { jg_backlog_task_id "$1" "$MODEL"; }
last_line() { grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | tr '\t\r' '  ' | cut -c1-200; }
first_line_of() { printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n 1 | tr '\t\r' '  ' | cut -c1-200; }

# --- A lane's life: a brief, then one start ----------------------------------------------------------------------
# live_record <task>: the task's published task record (one that only keeps a failed launch's copy is not one).
live_record() { [ -f "$STATE/$1.meta" ] && ! grep -q '^cleanup_recovery=' "$STATE/$1.meta" 2>/dev/null; }
# in_flight <task>: a spawn this command started still waits for its copy (no exit code yet, started less than WAIT s ago).
in_flight() {
  [ ! -f "$RUN/$1.rc" ] && [ -f "$RUN/$1.started" ] && [ $(( $(date +%s) - $(cat "$RUN/$1.started") )) -lt "$WAIT" ]
}
# ever_started <task>: the lane started once, so a lane that finished and was cleaned up is never started again.
ever_started() {
  live_record "$1" || in_flight "$1" || [ "$(cat "$RUN/$1.rc" 2>/dev/null)" = 0 ] || [ -s "$STATE/$1.status" ]
}

recon_lines() {  # <task>: the skill's "Each Recon's spec", after its first line
  # shellcheck disable=SC2016  # the backquotes are the brief's own text
  printf 'Run `%s/bin/jg-recon-handoff.sh draft %s` before your done line and `%s/bin/jg-recon-handoff.sh revise %s` after you fix a round'"'"'s gaps.\nYou may run `%s/bin/jg-captain-hold.sh hold` and `complete` for this task'"'"'s own decisions (captain-hold-lifecycle). Write no other backlog item.\nRound 3 is the last round that may report gaps. A gap you cannot close in one revision moves to section 7 or 10 with its reason, and the critic closes it as carried.' \
    "$JG_ROOT" "$1" "$JG_ROOT" "$1" "$JG_ROOT"
}
council_ref() {  # <what the lane does>: the problem is on the council ticket
  # shellcheck disable=SC2016  # the backquotes are the brief's own text
  printf 'War room council %s (%s): %s The council ticket holds the problem in full: read it with `%s/bin/jg-backlog.sh show %s --full`.' \
    "$COUNCIL" "$COUNCIL_TITLE" "$1" "$JG_ROOT" "$COUNCIL"
}

# write_brief <task> <row> <depth> <marker> <task text> <spec text>: prints why it could not, returns 1.
# The spec text starts with the marker line (`Angle: <angle>` or `Role: <role>`); a brief that holds the marker and the depth is kept.
write_brief() {
  local task=$1 row=$2 depth=$3 marker=$4 brief=$DATA/$1/brief.md
  if [ -e "$brief" ]; then
    if grep -qxF "$marker" "$brief" && { [ "$depth" = quick ] || grep -qxF "Recon depth: $depth" "$brief"; } \
      && ! grep -qE '\{TASK\}|\{JUGGERNAUT_SPEC\}' "$brief"; then
      return 0
    fi
    echo "a different brief is already at $brief"; return 1
  fi
  "$SCRIPT_DIR/jg-brief.sh" "$task" "$PROJECT" --scout --depth "$depth" --ticket "$row" >/dev/null 2>"$RUN/.brief.err" \
    || { echo "the brief was not written: $(last_line "$RUN/.brief.err")"; return 1; }
  TASK_FILL=$5 SPEC_FILL=$6 awk '
    BEGIN { t = ENVIRON["TASK_FILL"]; p = ENVIRON["SPEC_FILL"] }
    $0 == "{TASK}" { print t; next }
    $0 == "{JUGGERNAUT_SPEC}" { print p; next }
    { print }' "$brief" > "$brief.tmp"
  mv "$brief.tmp" "$brief" || { echo "the brief of $row could not be filled"; return 1; }
  ! grep -qE '\{TASK\}|\{JUGGERNAUT_SPEC\}' "$brief" || { echo "the brief of $row still holds a placeholder"; return 1; }
}

# launch <task> <row>: the lane starts now, in its own session, so it outlives this command when it waits for a copy;
# its exit code is its answer (data/war-room/<council>/<task>.rc), its output the .log beside it.
launch() {
  local task=${1:?} row=$2
  rm -f "${RUN:?}/$task.rc"
  date +%s > "$RUN/$task.started"
  # shellcheck disable=SC2016  # the shell of the lane expands its own arguments
  setsid nohup bash -c '"$@" > "$0.log" 2>&1 < /dev/null; echo $? > "$0.rc.tmp" && mv "$0.rc.tmp" "$0.rc"' "$RUN/$task" \
    "$SPAWN" "$task" "$PROJECT_DIR" --ticket "$row" --scout --harness "$HARNESS" --model "$MODEL" --effort "$EFFORT" \
    > /dev/null 2>&1 < /dev/null &
}

# --- start -------------------------------------------------------------------------------------------------------
cmd_start() {
  local need raw angle title row task why waited rc reason lane state status=0 lanes=() angle_list=()
  while [ $# -gt 0 ]; do
    case $1 in
      --project|--angles|--depth|--synthesis-depth|--harness|--model|--effort)
        [ $# -ge 2 ] || refuse "$1 needs a value"
        case $1 in
          --project) PROJECT=$2 ;; --angles) ANGLES=$2 ;; --depth) DEPTH=$2 ;; --synthesis-depth) SYNTH_DEPTH=$2 ;;
          --harness) HARNESS=$2 ;; --model) MODEL=$2 ;; --effort) EFFORT=$2 ;;
        esac
        shift ;;
      --no-variant-critics) VARIANT_CRITICS=0 ;;
      -*) refuse "unknown flag $1" ;;
      *) [ -z "$COUNCIL" ] || refuse "one council ticket only"; COUNCIL=$1 ;;
    esac
    shift
  done
  [ -n "$COUNCIL" ] || refuse "the council ticket is missing"
  for need in PROJECT ANGLES DEPTH HARNESS MODEL EFFORT; do
    [ -n "${!need}" ] || refuse "--$(printf '%s' "$need" | tr '[:upper:]' '[:lower:]') is missing"
  done
  SYNTH_DEPTH=${SYNTH_DEPTH:-$DEPTH}
  case $DEPTH in standard|deep) ;; *) refuse "--depth is standard or deep (got '$DEPTH')" ;; esac
  case $SYNTH_DEPTH in standard|deep) ;; *) refuse "--synthesis-depth is standard or deep (got '$SYNTH_DEPTH')" ;; esac
  [ "$VARIANT_CRITICS" = 1 ] || [ "$DEPTH" = standard ] \
    || refuse "--no-variant-critics needs --depth standard: a deep Recon's critic may not be its own"
  case $WAIT in ''|*[!0-9]*) refuse "JG_WAR_ROOM_WAIT is a whole number of seconds" ;; esac
  PROJECT_DIR=$PROJECTS/$PROJECT
  [ -d "$PROJECT_DIR" ] || refuse "no project $PROJECT: $PROJECT_DIR is not a directory"
  open_council "$COUNCIL"
  mkdir -p "$RUN" || refuse "cannot write $RUN"
  # What `next` needs to carry on from here; written before the first lane starts, so a draft that comes early finds it.
  printf 'council=%s\nproject=%s\nangles=%s\ndepth=%s\nharness=%s\nmodel=%s\neffort=%s\nsynthesis_depth=%s\nvariant_critics=%s\n' \
    "$COUNCIL" "$PROJECT" "$ANGLES" "$DEPTH" "$HARNESS" "$MODEL" "$EFFORT" "$SYNTH_DEPTH" "$VARIANT_CRITICS" > "$RUN/record.tmp"
  mv "$RUN/record.tmp" "$RUN/record" || refuse "cannot write $RUN/record"

  # Tickets and briefs, then every start at the same moment.
  IFS=',' read -ra angle_list <<< "$ANGLES"
  for raw in "${angle_list[@]}"; do
    angle=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$angle" ] || continue
    title="$angle variant Recon"
    row=$(lane_row "$title" "Run the $angle variant Recon of council $COUNCIL and write its report." \
      "The report passes bin/jg-recon-gate.sh and its critic has closed every gap." 2>"$RUN/.file.err") && [ -n "$row" ] \
      || { lanes+=("$angle"$'\t'-$'\t'"the ticket was not filed: $(last_line "$RUN/.file.err")"); continue; }
    task=$(task_of "$row")
    if live_record "$task"; then lanes+=("$angle"$'\t'"$task"$'\t'live); continue; fi
    why=$(write_brief "$task" "$row" "$DEPTH" "Angle: $angle" \
      "$(council_ref "run the $angle variant Recon of it.")" "$(printf 'Angle: %s\n%s' "$angle" "$(recon_lines "$task")")") \
      || { lanes+=("$angle"$'\t'"$task"$'\t'"$why"); continue; }
    launch "$task" "$row"
    lanes+=("$angle"$'\t'"$task"$'\t'start)
  done

  # Wait for each lane's record or exit code, and report.
  for lane in "${lanes[@]}"; do
    IFS=$'\t' read -r angle task state <<< "$lane"
    case $state in
      live) printf '%s: %s already live\n' "$angle" "$task"; continue ;;
      start) ;;
      *) if [ "$task" = - ]; then printf '%s: not started: %s\n' "$angle" "$state"
         else printf '%s: %s not started: %s\n' "$angle" "$task" "$state"; fi
         status=1; continue ;;
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
      status=1
    fi
  done
  return "$status"
}

# --- next --------------------------------------------------------------------------------------------------------
# read_record <fields...>: the record `start` wrote, into the globals named by the keys.
read_record() {
  local key value
  [ -s "$RUN/record" ] || refuse "no war room record for $COUNCIL (data/war-room/$COUNCIL/record): start it with jg-war-room.sh start"
  while IFS='=' read -r key value; do
    case $key in
      project) PROJECT=$value ;; angles) ANGLES=$value ;; depth) DEPTH=$value ;;
      harness) HARNESS=$value ;; model) MODEL=$value ;; effort) EFFORT=$value ;;
      synthesis_depth) SYNTH_DEPTH=$value ;; variant_critics) VARIANT_CRITICS=$value ;;
    esac
  done < "$RUN/record"
  SYNTH_DEPTH=${SYNTH_DEPTH:-$DEPTH}
  PROJECT_DIR=$PROJECTS/$PROJECT
}

# One `next` at a time for a council: events from three drafts at once queue behind each other, and each finds the work done.
LOCK=''
unlock_next() { rm -f "${LOCK:?}/pid"; rmdir "$LOCK" 2>/dev/null; }
lock_next() {
  local waited=0 pid
  LOCK=$RUN/.next.lock
  until mkdir "$LOCK" 2>/dev/null; do
    pid=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then unlock_next; continue; fi
    [ "$waited" -lt 600 ] || { echo "jg-war-room: another next of $COUNCIL still runs after 600 s" >&2; return 1; }
    sleep 1; waited=$((waited + 1))
  done
  echo $$ > "$LOCK/pid"
  trap unlock_next EXIT
}

phase_of() { "$HANDOFF" phase "$1" 2>/dev/null || echo none; }
gate_passes() { "$GATE" "$1" > /dev/null 2>&1; }
status_done() { [ "$(last_line "$STATE/$1.status" | cut -d' ' -f1)" = "done" ]; }
plan_waves() {  # <plan.json> -> "<slices> <waves>"
  jq -r '.slices as $s
    | def lvl($id): ($s | map(select(.id == $id))[0].depends_on // []) | if length == 0 then 1 else 1 + (map(lvl(.)) | max) end;
      "\($s | length) \([$s[].id | lvl(.)] | max)"' "$1"
}

WAITS='' STATUS=0 SYNTH_TASK='' DRY_TASK='' PLAN='' LANE_ROW='' LANE_TASK=''
VARIANTS=()   # the task of each angle, `-` when the council has no ticket for it yet

# One lane is one ticket, one brief and at most one start. A refusal prints its line and makes the exit 1.
run_lane() {  # <what> <title> <ask> <done> <depth> <marker> <task text> <spec text> -> sets LANE_ROW and LANE_TASK
  local what=$1 title=$2 why
  LANE_ROW=$(lane_row "$title" "$3" "$4" 2>"$RUN/.file.err") && [ -n "$LANE_ROW" ] \
    || { printf '%s: not started: the ticket was not filed: %s\n' "$what" "$(last_line "$RUN/.file.err")"; STATUS=1; LANE_ROW=''; return 1; }
  CHILDREN=''
  LANE_TASK=$(task_of "$LANE_ROW")
  why=$(write_brief "$LANE_TASK" "$LANE_ROW" "$5" "$6" "$7" "$(printf '%s\n%s' "$6" "$8")") \
    || { printf '%s: %s not started: %s\n' "$what" "$LANE_TASK" "$why"; STATUS=1; return 1; }
  ever_started "$LANE_TASK" && return 0
  launch "$LANE_TASK" "$LANE_ROW"
  printf '%s: %s started\n' "$what" "$LANE_TASK"
}

# a. A draft with no critic gets one, and the handoff names it.
step_critic() {  # <lane title> <lane task>
  local title=$1 lane=$2 out spec
  [ "$(phase_of "$lane")" = drafted ] || return 0
  # shellcheck disable=SC2016  # the backquotes are the brief's own text
  spec=$(printf 'Read the draft with the deep-recon critic rubric (.agents/skills/deep-recon/SKILL.md, "Critic rubric").\nWrite no report.md and no backlog item: your rounds go in critic.md through the verdict command.\nEnd each round with `%s/bin/jg-recon-handoff.sh verdict %s --critic CRITIC --hash <sha256 of %s/report.md> --gaps <k>`.' \
    "$JG_ROOT" "$lane" "$DATA/$lane")
  run_lane "critic of $lane" "$title critic" "Read the draft of $lane as its critic and close every gap with it." \
    "The critic's verdict is recorded with bin/jg-recon-handoff.sh verdict." quick "Role: critic of $lane" \
    "$(council_ref "you are the critic of $title (task $lane); its draft is $DATA/$lane/report.md.")" "$spec" || return 0
  # The verdict command names the critic's own task id, which is known once its ticket is.
  sed -i.bak "s|--critic CRITIC |--critic $LANE_TASK |" "$DATA/$LANE_TASK/brief.md" && rm -f "$DATA/$LANE_TASK/brief.md.bak"
  if out=$("$HANDOFF" assign "$lane" --critic "$LANE_TASK" 2>&1); then
    printf 'critic of %s: %s assigned\n' "$lane" "$LANE_TASK"
  else
    printf 'critic of %s: %s not assigned: %s\n' "$lane" "$LANE_TASK" "$(first_line_of "$out")"; STATUS=1
  fi
}

# b. Every variant past its gate, and no synthesis lane yet: the synthesis, with the three report paths.
step_synthesis() {
  local all=1 task reports=''
  for task in "${VARIANTS[@]}"; do
    if [ "$task" != - ] && gate_passes "$task"; then reports+=" $DATA/$task/report.md"; continue; fi
    all=0; [ -n "$WAITS" ] || WAITS="waits: $task $(phase_of "$task")"
  done
  [ "$all" = 1 ] || return 0
  # shellcheck disable=SC2016  # the backquotes are the brief's own text
  run_lane synthesis "synthesis Recon" "Write the synthesis of council $COUNCIL from its variant reports." \
    "The report passes bin/jg-recon-gate.sh, its critic has closed every gap and orders/plan.json passes bin/jg-swarm-plan-check.sh." \
    "$SYNTH_DEPTH" "Role: synthesis" "$(council_ref "write the synthesis of its variant reports:$reports.")" \
    "$(printf 'Run `strike-recon` at stage 1 on the variant reports above, and end with `op-order`: the work orders and the plan %s/<this task>/orders/plan.json, which `%s/bin/jg-swarm-plan-check.sh` must pass.\n%s' \
      "$DATA" "$JG_ROOT" "$(recon_lines '<this task>')")" || return 0
  SYNTH_TASK=$LANE_TASK
  sed -i.bak "s|<this task>|$SYNTH_TASK|g" "$DATA/$SYNTH_TASK/brief.md" && rm -f "$DATA/$SYNTH_TASK/brief.md.bak"
}

# c. The synthesis past its gate, and no dry-run lane yet: the dry run of order 1.
step_dry_run() {
  [ -n "$SYNTH_TASK" ] || return 0
  if ! gate_passes "$SYNTH_TASK"; then [ -n "$WAITS" ] || WAITS="waits: $SYNTH_TASK $(phase_of "$SYNTH_TASK")"; return 0; fi
  # shellcheck disable=SC2016  # the backquotes are the brief's own text
  run_lane "dry run" "dry run of order 1" "Dry-run order 1 of the plan of council $COUNCIL on a scratch copy." \
    "The dry run reports where order 1 got stuck and its measured wall time." quick "Role: dry run" \
    "$(council_ref "dry-run order 1 of its plan, $PLAN.")" \
    "$(printf 'Carry out the first slice of %s (its `order` file is beside the plan) on a scratch copy of the project, exactly as the order says.\nReport where you got stuck and the measured wall time. Land nothing and push nothing.' "$PLAN")" || return 0
  DRY_TASK=$LANE_TASK
}

# d. The dry run done and the plan good: the owner is asked once.
step_approval() {
  local check n w reason out
  if [ -f "$RUN/plan-asked" ]; then WAITS="waits: $COUNCIL plan-approval"; return 0; fi
  [ -n "$DRY_TASK" ] || return 0
  status_done "$DRY_TASK" || { [ -n "$WAITS" ] || WAITS="waits: $DRY_TASK running"; return 0; }
  check=$("$SCRIPT_DIR/jg-swarm-plan-check.sh" "$PLAN" 2>&1) \
    || { WAITS="waits: $SYNTH_TASK plan-check $(first_line_of "$check")"; return 0; }
  read -r n w <<< "$(plan_waves "$PLAN")"
  reason="Plan $(jq -r '.title' "$PLAN"): $n slices in $w waves. The plan file is $PLAN. Say yes and Main starts /blitz on it."
  out=$("$SCRIPT_DIR/jg-captain-hold.sh" hold "$COUNCIL" --must plan-approval --reason "$reason" 2>&1) \
    || { printf 'owner approval not asked: %s\n' "$(first_line_of "$out")"; STATUS=1; return 0; }
  printf '%s\n' "$PLAN" > "$RUN/plan-asked"
  echo "owner approval asked"
  WAITS=''
}

cmd_next() {
  local raw angle row task angle_list=()
  [ $# -eq 1 ] || refuse "$USAGE"
  open_council "$1"
  read_record
  [ -d "$PROJECT_DIR" ] || refuse "no project $PROJECT: $PROJECT_DIR is not a directory"
  if [ -f "$RUN/approved" ]; then echo "approved: nothing is due"; return 0; fi
  lock_next || return 1

  IFS=',' read -ra angle_list <<< "$ANGLES"
  for raw in "${angle_list[@]}"; do
    angle=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$angle" ] || continue
    row=$(child_titled "$angle variant Recon")
    if [ -z "$row" ]; then VARIANTS+=(-); [ -n "$WAITS" ] || WAITS="waits: $angle no lane"; continue; fi
    task=$(task_of "$row"); VARIANTS+=("$task")
    [ "$VARIANT_CRITICS" = 0 ] || step_critic "$angle variant Recon" "$task"
  done
  row=$(child_titled "synthesis Recon")
  if [ -n "$row" ]; then SYNTH_TASK=$(task_of "$row"); step_critic "synthesis Recon" "$SYNTH_TASK"; fi
  step_synthesis
  PLAN=$DATA/${SYNTH_TASK:-none}/orders/plan.json
  step_dry_run
  step_approval
  [ -z "$WAITS" ] || echo "$WAITS"
  return "$STATUS"
}

# --- approve -----------------------------------------------------------------------------------------------------
cmd_approve() {
  local words='' by=main plan rc out
  while [ $# -gt 0 ]; do
    case $1 in
      --words|--by) [ $# -ge 2 ] || refuse "$1 needs a value"; case $1 in --words) words=$2 ;; --by) by=$2 ;; esac; shift ;;
      -*) refuse "unknown flag $1" ;;
      *) [ -z "$COUNCIL" ] || refuse "one council ticket only"; COUNCIL=$1 ;;
    esac
    shift
  done
  [ -n "$COUNCIL" ] || refuse "the council ticket is missing"
  [ -n "${words//[[:space:]]/}" ] || refuse "--words takes the owner's words, quoted"
  RUN=$DATA/war-room/$COUNCIL
  read_record
  [ -s "$RUN/plan-asked" ] || refuse "the owner's plan approval was not asked yet: run jg-war-room.sh next $COUNCIL"
  plan=$(cat "$RUN/plan-asked")
  if grep -q '^swarm: started' "$RUN/approved" 2>/dev/null; then echo "already started"; return 0; fi
  [ -f "$RUN/approved" ] || printf 'by: %s\nat: %s\nwords: %s\n' "$by" "$(date +%s)" "$words" > "$RUN/approved"
  out=$("$SWARM" start "$plan" --harness "$HARNESS" --model "$MODEL" --effort "$EFFORT" 2>&1); rc=$?
  printf '%s\n' "$out"
  [ "$rc" = 0 ] || { echo "jg-war-room: the swarm did not start (exit $rc); run approve again after fixing it" >&2; return 1; }
  printf 'swarm: started %s\n' "$(date +%s)" >> "$RUN/approved"
}

# --- Dispatch ----------------------------------------------------------------------------------------------------
case ${1:-} in
  -h|--help) usage; exit 0 ;;
  start) shift; cmd_start "$@"; exit $? ;;
  next) shift; cmd_next "$@"; exit $? ;;
  approve) shift; cmd_approve "$@"; exit $? ;;
  *) refuse "$USAGE" ;;
esac
