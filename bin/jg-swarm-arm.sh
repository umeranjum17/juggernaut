#!/usr/bin/env bash
# jg-swarm-arm.sh - arm this home for its slices of a swarm plan: a brief for each slice, the owner's word gate for each
# owner-word slice, the gate of each slice that waits on a row of another home or on a tool, and the dispatch switch.
#
# Usage: jg-swarm-arm.sh <derived plan.json> [--agents <n>] [--with-others]
#        jg-swarm-arm.sh --help
#
# Run in the owner home: `main`, or the id in its .jg-squad-lead-home. The plan file is the derived plan that
# `bin/jg-swarm.sh start` writes (data/swarm/<plan>/plan.json): the input plan plus, on each slice, row, task, card,
# word_row, order_path, order_sha256 and goal. Only the slices whose owner_home is this home are armed.
# For each such slice, in this order:
#   1. Brief: bin/jg-brief.sh <task> <project> --mode <the project's mode> --ticket <row>, with the task part filled
#      (the work order's path and sha256, its goal, the swarm rules, the plan's prior art, and on an owner-word slice
#      the `Owner pick:` line). data/<row>/brief.md becomes a link to ../<task>/brief.md. A brief that holds
#      `Swarm order sha256: <order_sha256>` is kept as it is.
#   2. Owner word: when this home has no gate (open or closed) for the slice's card, `jg-captain-hold.sh design-card`
#      raises it on the slice's word row. Never `hold`, which in a lead home also writes to the parent channel.
#   3. Gate: bin/jg-plan-gate.sh add <row> --waits-for <home>:<row id>, or --tool <name> --min <version>; a gate for
#      the same condition that is open already is kept.
# Then it writes data/swarm/<plan>/arm.json (plan, plan_file, home, armed_at, state, switch_before, switch_wrote,
# lane_target_before, lane_target_wrote, agents, rows, words, gated), writes `on` to config/auto-dispatch and, with
# --agents, <n> to config/lane-target, and prints
#   armed <n> slices of <plan> in <owner>; <k> wait for the owner; <g> gated
# then starts one dispatch pass in the background so the first ready slices start now, not at the next check sweep
# (every 300 s): it runs this home's `state/auto-dispatch.check.sh`, the shim the watcher runs, detached, and never
# waits for it. It prints `dispatch started: the first ready slices start now`, or, with no executable shim,
# `dispatch waits for the next check sweep: no state/auto-dispatch.check.sh`. JG_SWARM_ARM_KICK=0 starts no pass.
# switch_before, lane_target_before and armed_at come from this plan's own arm.json when it exists, else (the first two)
# from the oldest other `armed` arm.json of this home, else from the files: the last swarm to finish puts back what
# was there before any swarm, and arming twice changes nothing.
#
# Refused (exit 2, nothing written): usage, a plan file that cannot be read, a task part over 4096 bytes, and an open
# row with a state/dispatch-approved/ record that is neither in this plan nor in the rows of an `armed` arm.json of
# this home, unless --with-others. Exit 1: a step failed after a write; arm.json is not written, and a run again
# keeps what is done (a brief, a gate) and does the rest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
# shellcheck source=bin/jg-compat.sh disable=SC1091
. "$SCRIPT_DIR/jg-compat.sh"
export JG_HOME

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
refuse() { printf 'jg-swarm-arm: %s\n' "$*" >&2; exit 2; }
die() { printf 'jg-swarm-arm: %s\n' "$*" >&2; exit 1; }

PLAN_FILE='' AGENTS='' OTHERS=0
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --agents) [ $# -ge 2 ] || refuse "--agents needs a number"; AGENTS=$2; shift ;;
    --with-others) OTHERS=1 ;;
    -*) refuse "unknown flag $1" ;;
    *) [ -z "$PLAN_FILE" ] || refuse "one plan file only"; PLAN_FILE=$1 ;;
  esac
  shift
done
[ -n "$PLAN_FILE" ] || refuse "usage: jg-swarm-arm.sh <derived plan.json> [--agents <n>] [--with-others]"
[ -r "$PLAN_FILE" ] || refuse "cannot read $PLAN_FILE"
case $AGENTS in ''|[1-9]*[0-9]|[1-9]) ;; *) refuse "--agents is a whole number above 0" ;; esac
case $AGENTS in *[!0-9]*) refuse "--agents is a whole number above 0" ;; esac
jq -e '(.plan | type) == "string" and (.slices | type) == "array"' "$PLAN_FILE" >/dev/null 2>&1 \
  || refuse "$PLAN_FILE is not a derived plan"
PLAN_FILE=$(cd "$(dirname "$PLAN_FILE")" && pwd)/$(basename "$PLAN_FILE")

PLAN=$(jq -r '.plan' "$PLAN_FILE")
OWNER=main
MARKER=$(jg_compat_marker "$JG_HOME")
[ ! -s "$MARKER" ] || OWNER=$(awk 'NF { print $1; exit }' "$MARKER")
SLICES=$(jq -c --arg o "$OWNER" '.slices[] | select(.owner_home == $o)' "$PLAN_FILE")
[ -n "$SLICES" ] || refuse "plan $PLAN has no slice for $OWNER"

backlog() { "$SCRIPT_DIR/jg-backlog.sh" "$@"; }
field() { jq -r --arg f "$2" '.[$f] // empty' <<< "$1"; }

RULES='Swarm rules: you were started because every slice this order depends on has landed.
Never wait for other slices of the plan, and never wait on a red trunk you did not cause; fix a red you caused in this lane.
Change no file outside the order'"'"'s Files list. If the same obstacle stops you twice, report blocked with the exact error.'

# The two fills of a slice's brief, as text: task_fill <slice json>, spec_fill <slice json>.
task_fill() {
  local intent
  intent=$(jq -r '.intent // ""' "$PLAN_FILE" | tr '\n' ' ')
  printf '%s\nThis is slice %s (%s) of plan %s; the work order named below is the whole task.' \
    "${intent:0:600}" "$(field "$1" id)" "$(field "$1" title)" "$PLAN"
}
spec_fill() {
  local s=$1 sha pick
  sha=$(field "$s" order_sha256)
  printf 'Work order: %s (sha256 %s). Read it in full before you start; it is the whole task, and its Files list is binding.\nGoal: %s\n%s\nSwarm order sha256: %s' \
    "$(field "$s" order_path)" "$sha" "$(field "$s" goal)" "$RULES" "$sha"
  if [ "$(jq -r '.owner_word != null' <<< "$s")" = true ]; then
    local q oa ob card
    q=$(jq -r '.owner_word.question' <<< "$s") oa=$(jq -r '.owner_word.options.a' <<< "$s") ob=$(jq -r '.owner_word.options.b' <<< "$s") card=$(field "$s" card)
    # shellcheck disable=SC2016  # the quotes are the brief's own text
    pick=$(printf 'Owner pick: %s Options: a %s; b %s. Read his answer with: JG_HOME=%s %s/bin/jg-backlog.sh questions --all --json | jq -r '"'"'first(.[] | select(.card == "%s" and .state == "closed") | .words) // empty'"'"'. Build the option he picked. If the command prints nothing, report blocked.' "$q" "$oa" "$ob" "$JG_HOME" "$JG_HOME" "$card")
    printf '\n%s' "$pick"
  fi
}

# Open rows: the lines of `list --all` that start with two spaces and not `  - `, the first two comma fields.
open_rows() { backlog list --all 2>/dev/null | awk -F, '/^  / && !/^  - / { id = $1; sub(/^ +/, "", id); if ($2 != "done") print id }'; }

# --- Refusals, before any write ---------------------------------------------------------------------------------
ROWS_NOW=$(jq -r --arg o "$OWNER" '.slices[] | select(.owner_home == $o) | .row' "$PLAN_FILE")
while IFS= read -r s; do
  [ -n "$(field "$s" row)" ] && [ -n "$(field "$s" task)" ] && [ -n "$(field "$s" order_path)" ] \
    || refuse "slice $(field "$s" id) of $PLAN has no row, task or order_path: the plan file is not a derived plan"
  size=$(( $(task_fill "$s" | wc -c) + $(spec_fill "$s" | wc -c) ))
  [ "$size" -lt 4096 ] || refuse "the task part of slice $(field "$s" id) is $size bytes; the limit is 4096"
done <<< "$SLICES"
if [ "$OTHERS" = 0 ] && [ -d "$STATE/dispatch-approved" ]; then
  KNOWN=$ROWS_NOW
  for f in "$DATA"/swarm/*/arm.json; do
    [ -e "$f" ] || continue
    KNOWN+=$'\n'$(jq -r 'select(.state == "armed") | .rows[]' "$f")
  done
  OPEN=$(open_rows)
  OTHER=()
  for f in "$STATE"/dispatch-approved/*; do
    [ -e "$f" ] || continue
    id=$(basename "$f")
    grep -qxF -- "$id" <<< "$OPEN" || continue
    grep -qxF -- "$id" <<< "$KNOWN" || OTHER+=("$id")
  done
  [ "${#OTHER[@]}" -eq 0 ] || refuse "${#OTHER[@]} open row(s) outside this plan are approved for dispatch and would start: ${OTHER[*]}; run again with --with-others to arm anyway"
fi

# --- Per slice: brief, owner word, gate -------------------------------------------------------------------------
GATES_JSON=$(backlog questions --all --json 2>/dev/null || echo '[]')
ROWS=() WORDS=() GATED=()
while IFS= read -r s; do
  row=$(field "$s" row) task=$(field "$s" task) brief=$DATA/$(field "$s" task)/brief.md
  sha=$(field "$s" order_sha256) project=$(field "$s" project)
  if ! grep -qxF "Swarm order sha256: $sha" "$brief" 2>/dev/null; then
    mode=$("$SCRIPT_DIR/jg-project-mode.sh" "$project" | awk '{ print $1 }')
    "$SCRIPT_DIR/jg-brief.sh" "$task" "$project" --mode "$mode" --ticket "$row" >/dev/null || die "the brief of $row was not written"
    t=$(task_fill "$s") p=$(spec_fill "$s") a=$(jq -r '.prior_art' "$PLAN_FILE")
    TASK_FILL=$t SPEC_FILL=$p ART_FILL=$a awk '
      BEGIN { t = ENVIRON["TASK_FILL"]; p = ENVIRON["SPEC_FILL"]; a = ENVIRON["ART_FILL"] }
      $0 == "{TASK}" { print t; next }
      $0 == "{JUGGERNAUT_SPEC}" { print p; next }
      /^Prior art \(survey\): </ { print "Prior art (survey): " a; next }
      { print }' "$brief" > "$brief.tmp" && mv "$brief.tmp" "$brief"
    grep -qE '\{TASK\}|\{JUGGERNAUT_SPEC\}' "$brief" && die "the brief of $row still holds a placeholder"
  fi
  mkdir -p "$DATA/$row"
  ln -sfn "../$task/brief.md" "$DATA/$row/brief.md"
  ROWS+=("$row")

  if [ "$(jq -r '.owner_word != null' <<< "$s")" = true ]; then
    word=$(field "$s" word_row) card=$(field "$s" card)
    WORDS+=("$word")
    if [ "$(jq -r --arg c "$card" '[.[] | select(.card == $c)] | length' <<< "$GATES_JSON")" = 0 ]; then
      "$SCRIPT_DIR/jg-captain-hold.sh" design-card "$card" --raised-by "$word" --title "$(jq -r '.owner_word.question' <<< "$s")" >/dev/null \
        || die "the owner's gate $card for $row was not made"
    fi
  fi

  if [ "$(jq -r '.gate != null' <<< "$s")" = true ]; then
    if [ "$(jq -r '.gate | has("waits_for")' <<< "$s")" = true ]; then
      gate_args=(--waits-for "$(jq -r '.gate.waits_for' <<< "$s")")
    else
      gate_args=(--tool "$(jq -r '.gate.tool' <<< "$s")" --min "$(jq -r '.gate.min' <<< "$s")")
    fi
    out=$("$SCRIPT_DIR/jg-plan-gate.sh" add "$row" "${gate_args[@]}" 2>&1) || case $out in *"already waits on"*) ;; *) die "the gate of $row was not added: $out" ;; esac
    GATED+=("$row")
  fi
done <<< "$SLICES"

# --- The record and the switch ----------------------------------------------------------------------------------
REC_DIR=$DATA/swarm/$PLAN REC=$REC_DIR/arm.json
mkdir -p "$REC_DIR"
first_word() { awk 'NF { print $1; exit }' "$1" 2>/dev/null || true; }
switch_before=$(first_word "$CONFIG/auto-dispatch") lane_before=$(first_word "$CONFIG/lane-target")
switch_before=${switch_before:-absent} lane_before=${lane_before:-absent}
armed_at=$(date +%s) agents_prev='' lane_wrote_prev=''
if [ -s "$REC" ]; then
  switch_before=$(jq -r '.switch_before' "$REC") lane_before=$(jq -r '.lane_target_before' "$REC") armed_at=$(jq -r '.armed_at' "$REC")
  agents_prev=$(jq -r '.agents // empty' "$REC") lane_wrote_prev=$(jq -r '.lane_target_wrote // empty' "$REC")
else
  oldest=$(for f in "$DATA"/swarm/*/arm.json; do if [ -e "$f" ]; then jq -c 'select(.state == "armed")' "$f"; fi; done | jq -s -c 'sort_by(.armed_at) | first // empty')
  if [ -n "$oldest" ]; then
    switch_before=$(jq -r '.switch_before' <<< "$oldest") lane_before=$(jq -r '.lane_target_before' <<< "$oldest")
  fi
fi
AGENTS=${AGENTS:-$agents_prev}
LANE_WROTE=${AGENTS:-$lane_wrote_prev}
arr() { if [ "$#" -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -R . | jq -s -c .; fi; }
jq -n --arg plan "$PLAN" --arg pf "$PLAN_FILE" --arg home "$OWNER" --argjson at "$armed_at" --arg sb "$switch_before" \
  --arg lb "$lane_before" --arg lw "$LANE_WROTE" --arg ag "$AGENTS" \
  --argjson rows "$(arr "${ROWS[@]}")" --argjson words "$(arr "${WORDS[@]+"${WORDS[@]}"}")" --argjson gated "$(arr "${GATED[@]+"${GATED[@]}"}")" \
  '{plan: $plan, plan_file: $pf, home: $home, armed_at: $at, state: "armed", switch_before: $sb, switch_wrote: "on",
    lane_target_before: $lb, lane_target_wrote: (if $lw == "" then null else ($lw | tonumber) end),
    agents: (if $ag == "" then null else ($ag | tonumber) end), rows: $rows, words: $words, gated: $gated}' > "$REC.tmp" \
  || die "the arm record was not written"
mv "$REC.tmp" "$REC"
mkdir -p "$CONFIG"
printf 'on\n' > "$CONFIG/auto-dispatch"
[ -z "$AGENTS" ] || printf '%s\n' "$AGENTS" > "$CONFIG/lane-target"
printf 'armed %s slices of %s in %s; %s wait for the owner; %s gated\n' "${#ROWS[@]}" "$PLAN" "$OWNER" "${#WORDS[@]}" "${#GATED[@]}"

# One dispatch pass now: the watcher's own shim, detached; arming never waits for it.
shim=$STATE/auto-dispatch.check.sh
if [ ! -x "$shim" ]; then
  echo "dispatch waits for the next check sweep: no state/auto-dispatch.check.sh"
elif [ "${JG_SWARM_ARM_KICK:-1}" != 0 ]; then
  setsid nohup "$shim" >/dev/null 2>&1 </dev/null &
  echo "dispatch started: the first ready slices start now"
fi
