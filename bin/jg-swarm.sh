#!/usr/bin/env bash
# jg-swarm.sh - Main starts a swarm: files, approves and briefs every slice of a plan file, posts each owner-only
# question as a board card, and arms every owner home, so each slice starts on the first beat after its bases land.
#
# Usage: jg-swarm.sh start <plan.json> --harness <h> --model <m> --effort <e> [--agents <n>] [--with-others] [--wait]
#        jg-swarm.sh --help
#
# Main only. The plan file is the input form of bin/jg-swarm-plan-check.sh.
# `start` runs every check that writes nothing in the foreground (a refusal is printed, exit 2), then starts the work as a
# background job that no caller's time bound can stop, and returns within seconds:
#   swarm <plan>: started in the background; follow it with bin/jg-swarm-check.sh status <plan>
# The job is `jg-swarm.sh run <the same arguments>` in its own systemd user unit (jg-swarm-<plan>-<epoch>) when systemd-run exists,
# else under setsid nohup; its output is data/swarm/<plan>/start.log. It holds data/swarm/<plan>/.run.lock for its whole life, so
# `start` while a job runs prints `swarm <plan>: already running (log data/swarm/<plan>/start.log)` and exits 0, and `start` after a
# stopped job resumes it: a record left at `starting` files nothing twice. `start --wait` runs the job in the foreground and prints
#   swarm <plan>: <n> slices filed and approved in <owner>[, <owner>...]; <k> wait for the owner
# Exit codes: 0 started, already running, or done; 1 failed after a write (data/swarm/<plan>/swarm.json says what is done);
# 2 refused, nothing written.
#
# Refused before the first write: a plan the plan check refuses (its `refused:` lines are printed), a slice whose project
# has yolo off in its owner's home, a Squad Lead home, a swarm that is running or finished, a bad flag.
#
# Writes data/swarm/<plan>/swarm.json (state starting, then running) and records each finished step in `steps`:
#   checked    plan check, yolo of each owner home, not a Squad Lead home (before the first write)
#   copied     orders/ (read-only copies) and plan.json, the derived plan: the input plus on each slice body, order_path,
#              order_sha256, goal, and on an owner-word slice word_row; at the top main_home and owner_homes
#   plan-rows  the plan row in Main and in each owner home that lacks it; each word row in Main and in its slice's owner home
#   routed     bin/jg-plan-route.sh --dry-run, then the route itself; each slice's row and task go into the derived plan.
#              A dry-run refusal exits 1 and leaves the record at plan-rows
#   approved   bin/jg-plan-gate.sh approve
#   cards      the board card of each owner-word slice (--route main, or the lead's task; never --decision-key)
#   armed:main bin/jg-swarm-arm.sh in Main, when Main owns a slice
#   sent:<id>  one message to each lead: run bin/jg-swarm-arm.sh on the derived plan
# Test hooks: JG_SWARM_SEND (default bin/jg-send.sh), JG_SWARM_CARD (default bin/jg-question-card.sh),
# JG_SWARM_ARM (default bin/jg-swarm-arm.sh), JG_SWARM_STEP_DELAY=<s> (the job sleeps that long before each step it runs).
# shellcheck disable=SC2016 # jq programs hold $vars on purpose.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
# shellcheck source=bin/jg-compat.sh disable=SC1091
. "$SCRIPT_DIR/jg-compat.sh"
# shellcheck source=bin/jg-squad-lead-registry-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"
# shellcheck source=core/trunk-landing/unit.sh disable=SC1091
. "$SCRIPT_DIR/../core/trunk-landing/unit.sh"
export JG_HOME
SEND=${JG_SWARM_SEND:-$SCRIPT_DIR/jg-send.sh}
CARD=${JG_SWARM_CARD:-$SCRIPT_DIR/jg-question-card.sh}
ARM=${JG_SWARM_ARM:-$SCRIPT_DIR/jg-swarm-arm.sh}

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
refuse() { printf 'jg-swarm: %s\n' "$*" >&2; exit 2; }
die() { printf 'jg-swarm: %s\n' "$*" >&2; exit 1; }

USAGE="usage: jg-swarm.sh start <plan.json> --harness <h> --model <m> --effort <e> [--agents <n>] [--with-others] [--wait]"
MODE=''  # start: the checks, then the job; run: the job (what start starts in the background)
case ${1-} in
  -h | --help) usage; exit 0 ;;
  start | run) MODE=$1; shift ;;
  *) refuse "$USAGE" ;;
esac
IN='' HARNESS='' MODEL='' EFFORT='' AGENTS='' OTHERS=() WAIT=0
while [ $# -gt 0 ]; do
  case $1 in
    -h | --help) usage; exit 0 ;;
    --harness | --model | --effort | --agents)
      [ $# -ge 2 ] || refuse "$1 needs a value"
      case $1 in --harness) HARNESS=$2 ;; --model) MODEL=$2 ;; --effort) EFFORT=$2 ;; --agents) AGENTS=$2 ;; esac
      shift ;;
    --with-others) OTHERS=(--with-others) ;;
    --wait) [ "$MODE" = start ] || refuse "--wait belongs to start"; WAIT=1 ;;
    -*) refuse "unknown flag $1" ;;
    *) [ -z "$IN" ] || refuse "one plan file only"; IN=$1 ;;
  esac
  shift
done
[ -n "$IN" ] && [ -n "$HARNESS" ] && [ -n "$MODEL" ] && [ -n "$EFFORT" ] \
  || refuse "$USAGE"
[ -r "$IN" ] || refuse "cannot read $IN"
case $AGENTS in '' | [1-9] | [1-9]*[0-9]) ;; *) refuse "--agents is a whole number above 0" ;; esac
case $AGENTS in *[!0-9]*) refuse "--agents is a whole number above 0" ;; esac
IN=$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")
[ ! -e "$(jg_compat_marker "$JG_HOME")" ] || refuse "this is a Squad Lead home: only Main starts a swarm"

# --- homes: Main's own, and each lead's from Main's registry ------------------------------------------------------------
REG=$(jg_compat_pick "$DATA/squad_leads.md")
home_of() {  # <owner>: its absolute home path
  [ "$1" != main ] || { printf '%s\n' "$JG_HOME"; return; }
  case $1 in *[!A-Za-z0-9._-]*) return 1 ;; esac
  squad_lead_registry_line_for_id "$REG" "$1" && [ "$SQUAD_LEAD_REGISTRY_REMOTE" = 0 ] && [ -d "$SQUAD_LEAD_REGISTRY_HOME" ] \
    && printf '%s\n' "$SQUAD_LEAD_REGISTRY_HOME"
}
in_home() {  # <owner> <command...>: the command in that owner's home, its rows owned by it
  local owner=$1 h
  shift
  h=$(home_of "$owner") || return 1
  if [ "$owner" = main ]; then
    JG_ROW_OWNER=main JG_HOME="$h" "$@"
  else
    env -u JG_CONFIG_OVERRIDE -u JG_STATE_OVERRIDE -u JG_DATA_OVERRIDE -u JG_ROOT_OVERRIDE JG_ROW_OWNER="$owner" JG_HOME="$h" "$@"
  fi
}
backlog() { "$SCRIPT_DIR/jg-backlog.sh" "$@"; }

# --- 1. checked ---------------------------------------------------------------------------------------------------------
if ! out=$("$SCRIPT_DIR/jg-swarm-plan-check.sh" "$IN" 2>&1); then printf '%s\n' "$out"; exit 2; fi
PLAN=$(jq -r '.plan' "$IN")
mapfile -t OWNERS < <(jq -r '[.slices[].owner_home] | unique | (map(select(. == "main")) + map(select(. != "main")))[]' "$IN")
for owner in "${OWNERS[@]}"; do
  home_of "$owner" >/dev/null || refuse "owner $owner is neither main nor a local Squad Lead with a home in $REG"
done
while IFS=$'\t' read -r owner project slice; do
  mode=$(in_home "$owner" "$SCRIPT_DIR/jg-project-mode.sh" "$project" 2>/dev/null) || mode=
  [ "${mode##* }" = on ] || refuse "refused: $slice: project $project has yolo off in $owner (${mode:-no posture}); a swarm needs yolo on"
done < <(jq -r '.slices[] | [.owner_home, .project, .id] | @tsv' "$IN")

# --- 2. the job: started in the background, or run here -------------------------------------------------------------------
DIR=$DATA/swarm/$PLAN
REC=$DIR/swarm.json DERIVED=$DIR/plan.json LOCK=$DIR/.run.lock LOG=$DIR/start.log
lock_held() {  # a run of this plan is alive: its lock names a live pid
  local pid
  pid=$(cat "$LOCK/pid" 2>/dev/null) || return 1
  case $pid in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}
already_running() { printf 'swarm %s: already running (log data/swarm/%s/start.log)\n' "$PLAN" "$PLAN"; exit 0; }
refuse_if_past_starting() {
  [ ! -e "$REC" ] || [ "$(jq -r '.state' "$REC")" = starting ] \
    || refuse "swarm $PLAN is already $(jq -r '.state' "$REC"); see: bin/jg-swarm-check.sh status $PLAN"
}
detach() {  # `run` with this call's arguments, outside this caller's process tree and time bound
  local run=("$SCRIPT_DIR/jg-swarm.sh" run "$IN" --harness "$HARNESS" --model "$MODEL" --effort "$EFFORT") sd name keep=()
  [ -z "$AGENTS" ] || run+=(--agents "$AGENTS")
  run+=(${OTHERS[@]+"${OTHERS[@]}"})
  mkdir -p "$DIR"
  sd=$(unit_tool systemd-run)
  if [ -n "$sd" ]; then
    while IFS= read -r name; do keep+=("--setenv=$name"); done < <(compgen -e | grep -E '^(JG_|BEADS_|BD_|DOLT_|XDG_|LC_|LANG$|PATH$|HOME$|TMPDIR$)')
    "$sd" --user --collect --quiet --unit="jg-swarm-${PLAN//[^A-Za-z0-9_.-]/_}-$(date +%s)" --working-directory="$PWD" "${keep[@]}" \
      --property=StandardOutput=append:"$LOG" --property=StandardError=append:"$LOG" "${run[@]}" >/dev/null 2>&1 && return 0
  fi
  setsid nohup "${run[@]}" >> "$LOG" 2>&1 < /dev/null &
}
lock_held && already_running
refuse_if_past_starting
if [ "$MODE" = start ] && [ "$WAIT" = 0 ]; then
  detach
  printf 'swarm %s: started in the background; follow it with bin/jg-swarm-check.sh status %s\n' "$PLAN" "$PLAN"
  exit 0
fi
# The job: it holds the lock for its whole life; a lock left by a dead run is taken over by the next one.
# shellcheck source=bin/jg-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-wake-lib.sh"
mkdir -p "$DIR"
jg_lock_try_acquire "$LOCK" || already_running
trap 'jg_lock_release "$LOCK"' EXIT
step_delay() { [ -z "${JG_SWARM_STEP_DELAY:-}" ] || sleep "$JG_SWARM_STEP_DELAY"; }
refuse_if_past_starting

# --- 3. the record ------------------------------------------------------------------------------------------------------
if [ ! -e "$REC" ]; then
  owners_json=$(for owner in "${OWNERS[@]}"; do
    task=$owner
    jq -n --arg o "$owner" --arg h "$(home_of "$owner")" --arg t "$task" '{($o): {home: $h, task: $t}}'
  done | jq -s 'add')
  jq -n --arg plan "$PLAN" --arg pf "$DERIVED" --argjson at "$(date +%s)" --arg h "$HARNESS" --arg m "$MODEL" --arg e "$EFFORT" \
    --arg agents "$AGENTS" --argjson owners "$owners_json" \
    '{plan: $plan, plan_file: $pf, started_at: $at, state: "starting", steps: ["checked"],
      profile: {harness: $h, model: $m, effort: $e}, agents: (if $agents == "" then null else ($agents | tonumber) end), owners: $owners}' \
    > "$REC.new"
  (set -C; cat "$REC.new" > "$REC") 2>/dev/null || { rm -f "$REC.new"; refuse "swarm $PLAN is being started by another run"; }
  rm -f "$REC.new"
fi
done_step() { jq -e --arg s "$1" '.steps | index($s) != null' "$REC" >/dev/null; }
mark() { jq --arg s "$1" '.steps += [$s]' "$REC" > "$REC.new" && mv "$REC.new" "$REC"; }
edit_plan() { jq "$@" "$DERIVED" > "$DERIVED.new" && mv "$DERIVED.new" "$DERIVED"; }
slice_field() { jq -r --arg s "$1" --arg f "$2" '.slices[] | select(.id == $s) | .[$f] // empty' "$DERIVED"; }

# --- 4. copied ----------------------------------------------------------------------------------------------------------
sections() {  # <ask> <why> <done when> <acceptance>: the five sections of a row (interface section 6)
  printf '## Captain\n%s\n\n## Ask\n%s\n\n## Why\n%s\n\n## Done when\n%s\n\n## Acceptance Criteria\n%s\n' "${INTENT:0:300}" "$1" "$2" "$3" "$4"
}
INTENT=$(jq -r '.intent' "$IN")
if ! done_step copied; then
  step_delay
  mkdir -p "$DIR/orders"
  cp "$IN" "$DERIVED"
  edit_plan --arg h "$JG_HOME" '. + {main_home: $h, owner_homes: {}}'
  for owner in "${OWNERS[@]}"; do edit_plan --arg o "$owner" --arg h "$(home_of "$owner")" '.owner_homes[$o] = $h'; done
  while IFS=$'\t' read -r id order title word; do
    copy=$DIR/orders/$order
    mkdir -p "$(dirname "$copy")"
    cp -f "$(dirname "$IN")/$order" "$copy"
    chmod a-w "$copy"
    goal=$(awk '/^## Goal[[:space:]]*$/ { g = 1; next } g && /^#/ { exit } g && NF { print; exit }' "$copy")
    [[ $goal =~ ^([^.!?]*[.!?])([[:space:]]|$) ]] && goal=${BASH_REMATCH[1]}
    goal=${goal:0:200}
    body=$(sections "Build slice $id, $title, as its work order says." "Slice $id of plan $PLAN; work order $copy." \
      "Every Acceptance command of $copy gives its expected output." "The Acceptance section of $copy.")
    wrow=null
    [ "$word" = true ] && { wrow="\"$PLAN-word-$id\""; body+=$'\n\n'"linked-to: $PLAN-word-$id"; }
    edit_plan --arg id "$id" --arg p "$copy" --arg sha "$(sha256sum "$copy" | cut -d' ' -f1)" --arg goal "${goal:-$title}" \
      --arg body "$body" --argjson w "$wrow" \
      '.slices |= map(if .id == $id then . + {body: $body, order_path: $p, order_sha256: $sha, goal: $goal}
        + (if $w then {word_row: $w} else {} end) else . end)'
  done < <(jq -r '.slices[] | [.id, .order, .title, (.owner_word != null)] | @tsv' "$IN")
  mark copied
fi

# --- 5. plan-rows -------------------------------------------------------------------------------------------------------
add_row() {  # <owner> <id> <title> <project> <ask>: skipped when the row exists
  local owner=$1 id=$2
  in_home "$owner" "$SCRIPT_DIR/jg-backlog.sh" show "$id" >/dev/null 2>&1 && return 0
  in_home "$owner" "$SCRIPT_DIR/jg-backlog.sh" add "$id" "$3" --priority 2 --kind ship --repo "$4" \
    --body "$(sections "$5" "Plan $PLAN of the swarm; report $(jq -r '.report' "$IN")." "Every slice of plan $PLAN has landed." \
      "Every slice row of plan $PLAN is done.")" >/dev/null || die "could not file $id in $owner"
}
if ! done_step plan-rows; then
  step_delay
  first_project=$(jq -r '.slices[0].project' "$IN")
  PLAN_TITLE=$(jq -r '.title' "$IN")
  for owner in main "${OWNERS[@]}"; do
    add_row "$owner" "$PLAN" "[feature] $PLAN_TITLE" "$first_project" "Run the plan $PLAN as a swarm."
  done
  while IFS=$'\t' read -r id owner project; do
    for h in main "$owner"; do
      add_row "$h" "$PLAN-word-$id" "Owner pick before slice $id" "$project" "Hold slice $id of plan $PLAN until the owner picks."
      [ "$owner" != main ] || break
    done
  done < <(jq -r '.slices[] | select(.owner_word != null) | [.id, .owner_home, .project] | @tsv' "$IN")
  mark plan-rows
fi

# --- 6. routed ----------------------------------------------------------------------------------------------------------
if ! done_step routed; then
  step_delay
  out=$("$SCRIPT_DIR/jg-plan-route.sh" "$DERIVED" --dry-run 2>&1) || die "$out"
  out=$("$SCRIPT_DIR/jg-plan-route.sh" "$DERIVED" 2>&1) || die "$out"
  while read -r _ id _ row; do
    edit_plan --arg id "$id" --arg row "$row" '.slices |= map(if .id == $id then . + {row: $row, task: ($row | gsub("\\."; "-"))} else . end)'
  done < <(printf '%s\n' "$out" | grep -E '^filed [a-z0-9]+ as ')
  [ "$(jq '[.slices[] | select(.row == null)] | length' "$DERIVED")" = 0 ] || die "the route did not file every slice: $out"
  mark routed
fi

# --- 7. approved --------------------------------------------------------------------------------------------------------
if ! done_step approved; then
  step_delay
  "$SCRIPT_DIR/jg-plan-gate.sh" approve "$DERIVED" --harness "$HARNESS" --model "$MODEL" --effort "$EFFORT" >/dev/null \
    || die "the approval of plan $PLAN failed"
  mark approved
fi

# --- 8. cards -----------------------------------------------------------------------------------------------------------
if ! done_step cards; then
  step_delay
  while IFS=$'\t' read -r id owner; do
    [ -z "$(slice_field "$id" card)" ] || continue
    route=main
    [ "$owner" = main ] || route=$owner
    q=$(jq -r --arg s "$id" '.slices[] | select(.id == $s) | .owner_word
      | .question, .options.a, .options.b, .recommend, .why, .outcomes.a, .outcomes.b, .recommend_reason, .default' "$DERIVED")
    { read -r question; read -r a; read -r b; read -r rec; read -r why; read -r oa; read -r ob; read -r rr; read -r def; } <<< "$q"
    key=$("$CARD" post --ask-ref "$PLAN-word-$id" --title "$question" --must design-pick --raised-by "$PLAN-word-$id" --route "$route" \
      --option "a=$a" --option "b=$b" --recommend "$rec" --why "$why" --outcome "a=$oa" --outcome "b=$ob" \
      --recommend-reason "$rr" --default "$def") || die "the card of slice $id was refused"
    [ -n "$key" ] || die "the card of slice $id printed no key"
    edit_plan --arg id "$id" --arg k "$key" '.slices |= map(if .id == $id then . + {card: $k} else . end)'
  done < <(jq -r '.slices[] | select(.owner_word != null) | [.id, .owner_home] | @tsv' "$DERIVED")
  mark cards
fi

# --- 9. armed:main, sent:<lead> -----------------------------------------------------------------------------------------
ARM_ARGS=()
[ -z "$AGENTS" ] || ARM_ARGS=(--agents "$AGENTS")
for owner in "${OWNERS[@]}"; do
  if [ "$owner" = main ]; then
    done_step armed:main || { step_delay; "$ARM" "$DERIVED" ${ARM_ARGS[@]+"${ARM_ARGS[@]}"} ${OTHERS[@]+"${OTHERS[@]}"} >/dev/null || die "arming Main failed"; mark armed:main; }
  else
    done_step "sent:$owner" || {
      step_delay
      "$SEND" "$owner" "Swarm $PLAN is routed to you. Run: bin/jg-swarm-arm.sh $DERIVED${AGENTS:+ --agents $AGENTS}" >/dev/null \
        || die "the message to $owner was not sent"
      mark "sent:$owner"
    }
  fi
done

# --- 10. running ---------------------------------------------------------------------------------------------------------
jq '.state = "running"' "$REC" > "$REC.new" && mv "$REC.new" "$REC"
printf 'swarm %s: %s slices filed and approved in %s; %s wait for the owner\n' "$PLAN" "$(jq '.slices | length' "$DERIVED")" \
  "$(printf '%s\n' "${OWNERS[@]}" | paste -sd, - | sed 's/,/, /g')" "$(jq '[.slices[] | select(.owner_word != null)] | length' "$DERIVED")"
