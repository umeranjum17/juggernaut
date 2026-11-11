#!/usr/bin/env bash
# jg-escalation-workflows.sh - a stuck lane's owner alert and pause cadence as
# one declarative workflow definition, LIVE: this script decides and delivers
# those two rungs on every watcher poll.
#
# WHY THIS EXISTS (migration step 5c). The timer was shell: the owner alert
# threshold and the pause cadence were built by hand inside
# core/wait-timers/bin/jg-wait-timers-lib.sh, and procevent, ask-default,
# lead-wake, fleet-stall, nm-drain and merge-on-green each carried a copy of the
# same shape. The decided shape is one workflow definition with timers and
# external events, so a new threshold is a config line plus a test and never a
# core code change. This step puts that definition in charge of the rungs it
# carries: the owner alert at JG_WAIT_ALERT_SECS (120s) for a lane in a declared
# wait, and the pause cadence at JG_PAUSE_RESURFACE_SECS (14400s) for a lane in
# a declared pause. The escalation rung, the board card and the re-alert cadence
# are still the ladder's own (core/wait-timers/README.md), and the definition
# grows to carry them next.
#
# CONTRACT (this header is the one owner of the timer's shape).
#   definition  core/bus/workflows/escalation-wait-timers.json, overridable per home
#               at config/escalation-workflows.json or by JG_ESCALATION_WORKFLOW.
#               It owns the rungs, which timer each rung fires on, each timer's
#               seconds and the environment name it answers to, the ladder a wait
#               class uses, the wait-source priority and the episode key template.
#   facts       The one thing the definition does not own is how a fact is read:
#               a status log, a wait source, the pause-until token and the captain
#               hold are read with the same shared libraries the ladder code reads
#               them with (bin/jg-classify-lib.sh, bin/jg-wake-lib.sh,
#               bin/jg-backend.sh). Facts are gathered, policy decides.
#   show        Print the definition in force with every timer's effective value,
#               so a drift between the shell default and the definition is visible
#               without running anything.
#   timers      Print <timer> <seconds> for every timer the definition carries. The
#               ladder reads the two numbers it still measures its own rungs from
#               here, so neither number exists a second time in shell code.
#   tick        The live rung. Once per watcher poll, for every open episode the
#               ladder recorded, deliver the rungs this definition says are due and
#               none it does not: queue the wake under <key>-owner, stamp the
#               episode's own owner time so the rungs the ladder still owns keep
#               their timing, and print the wake line for the caller to deliver.
#               One wake per poll, as the ladder's own fire was. A tick that cannot
#               read its definition fails loudly and leaves the rest of the poll
#               running.
#
# Delivery stays the ladder's: the wake line this prints names the same rungs, the
# same decision key and the same source it named before the switch, and the wake
# queue, the routing rules and the session's own delivery are unchanged.
#
# Usage:
#   jg-escalation-workflows.sh show
#   jg-escalation-workflows.sh timers
#   jg-escalation-workflows.sh tick
set -u
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
CONFIG=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
# shellcheck source=core/wait-timers/bin/jg-wait-policy-lib.sh
. "$ROOT/core/wait-timers/bin/jg-wait-policy-lib.sh"

die() { printf 'jg-escalation-workflows: %s\n' "$*" >&2; exit 2; }
say() { printf '%s\n' "$*" >&2; }

definition() {  # the workflow definition file in force
  local f
  for f in "${JG_ESCALATION_WORKFLOW:-}" "$CONFIG/escalation-workflows.json" \
    "$ROOT/core/bus/workflows/escalation-wait-timers.json"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    printf '%s' "$f"
    return 0
  done
  return 1
}

wf() { jq -er "$1" "$DEF"; }  # one field of the definition in force

# A rung timer's seconds: the environment override the definition names wins,
# then the definition's own value. The ladder code reads the same names, so a
# default that drifted apart shows up in one place rather than as a second copy
# of the number here.
timer_secs() {  # <timer-name>
  local name=$1 env value
  env=$(wf ".spec.timers[\"$name\"].env // empty") || return 1
  value=$(wf ".spec.timers[\"$name\"].seconds // empty") || return 1
  timer_resolve "$name" "$env" "$value"
}

# The one rule for a timer's seconds, whichever read of the definition found them.
timer_resolve() {  # <timer-name> <env-name> <definition-seconds>
  local name=$1 env=$2 value=$3
  if [ -n "$env" ] && [ -n "${!env:-}" ]; then value=${!env}; fi
  case "$value" in
    '' | *[!0-9]* | 0*) die "timer $name is not positive decimal seconds: ${value:-<empty>}" ;;
  esac
  printf '%s' "$value"
}

# The actor the wake line names, as the ladder code named it.
actor_text() {
  if [ -e "$JG_HOME/.jg-squad-lead-home" ]; then printf 'owning lead'; else printf 'Main'; fi
}

# One ladder rung per line: <rung> <timer-seconds> <actor-or-*>.
ladder_rungs() {  # <wait|pause>
  local class=$1 rung timer actor
  while IFS=$'\t' read -r rung timer actor; do
    [ -n "$rung" ] || continue
    [ "$actor" != '-' ] || actor='*'
    printf '%s\t%s\t%s\n' "$rung" "$(timer_secs "$timer")" "$actor"
  done <<EOF
$(wf ".spec.ladders[\"$class\"].rungs[]? | [.rung, .timer, (.actor // \"-\")] | @tsv" 2>/dev/null)
EOF
}

ladder_realert_secs() {  # <wait|pause>
  local timer
  timer=$(wf ".spec.ladders[\"$1\"][\"re-alert\"] // empty") || return 1
  [ -n "$timer" ] || return 1
  timer_secs "$timer"
}

# The timer one rung of one ladder fires on, in seconds.
ladder_rung_secs() {  # <wait|pause> <rung>
  local class=$1 rung=$2 timer
  timer=$(wf ".spec.ladders[\"$class\"].rungs[]? | select(.rung == \"$rung\") | .timer" 2>/dev/null) || return 1
  [ -n "$timer" ] || return 1
  timer_secs "$timer"
}

# ---------------------------------------------------------------------------
# The facts. Gathered as the ladder code gathers them; the definition decides
# what to do with them. Prints <class> <source> <window> <declaration> <verb>,
# or nothing when the lane is in no wait.
# ---------------------------------------------------------------------------
wf_facts() {  # <task>
  local task=$1 meta="$STATE/$1.meta" window decl='' wsrc='' dkey='' rows
  local until name rule record old verb native fresh wait_state
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  window=$(jg_backend_target_of_meta "$meta")
  fresh=$(( ${POLL:-15} * 3 + 30 ))
  while read -r name rule; do
    record="$STATE/.wait-sources/$task.$name"
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    # A rule is any (never lapses), fresh (three polls and thirty seconds), or
    # the seconds of the timer the source's lapse names.
    case "$rule" in
      any) ;;
      fresh) [ "$(age_of "$record")" -lt "$fresh" ] || continue ;;
      *) [ "$(age_of "$record")" -lt "$rule" ] || continue ;;
    esac
    decl=$(head -n 1 "$record" | tr '\t' ' ' | cut -c1-300)
    wsrc=$name
    [ -z "$decl" ] || break
  done <<EOF
$WF_SOURCES
EOF
  if [ -z "$decl" ]; then
    rows=$(status_own_open_decisions "$STATE/$task.status")
    while IFS=$'\t' read -r old verb native; do
      case "$verb" in
        blocked | needs-decision) decl="$verb [key=$old]: $native"; dkey=$old ;;
      esac
    done <<EOF
$rows
EOF
    [ -n "$decl" ] || decl=$(status_declared_wait_line "$STATE/$task.status")
    if ! status_is_paused "$decl"; then
      case "$decl" in
        blocked* | needs-decision*) ;;
        *) decl='' ;;
      esac
    fi
  fi
  wait_state=''
  if status_is_paused "$decl"; then
    wait_state=$(jg_wait_machine_state "$SCRIPT_DIR" "$task") || return 1
  fi
  if [ "$wait_state" != paused-no-date ] && status_is_paused "$decl" && until=$(status_paused_until "$decl") && [ "$WF_NOW" -lt "$until" ]; then
    decl=''
  fi
  if [ -n "$decl" ] && declare -F task_captain_call_open >/dev/null && task_captain_call_open "$task"; then
    decl=''
  fi
  [ -n "$decl" ] || return 1
  # The verb the wake line carries: a decision names its key after the verb, a
  # wait source names itself, and a declared pause keeps its own verb.
  if [ -n "$dkey" ]; then
    verb="$(status_line_verb "$decl") key=$dkey"
  elif [ -n "$wsrc" ]; then
    verb=$wsrc
  else
    verb=$(status_line_verb "$decl")
  fi
  if status_is_paused "$decl"; then
    printf 'pause\t%s\t%s\t%s\t%s\n' "$(_jg_decision_key "$decl" || printf default)" "$window" "$decl" "$verb"
  else
    printf 'wait\t%s\t%s\t%s\t%s\n' "${dkey:-$wsrc}" "$window" "$decl" "$verb"
  fi
}

# ---------------------------------------------------------------------------
# show
# ---------------------------------------------------------------------------
cmd_show() {
  local rung rungsecs actor class timer env cadence
  printf 'workflow: %s (%s)\n' "$(wf '.metadata.name')" "$(wf '.metadata.mode')"
  printf 'definition: %s\n' "$DEF"
  [ -z "$(wf '.metadata.half // empty')" ] || printf 'half: %s\n' "$(wf '.metadata.half')"
  printf 'authoritative: %s\n' "$(wf '.metadata.authoritative')"
  printf 'key: %s\n' "$(wf '.spec.key')"
  printf 'timers:\n'
  while IFS=$'\t' read -r timer env; do
    [ -n "$timer" ] || continue
    printf '  %-14s %ss  (env %s)\n' "$timer" "$(timer_secs "$timer")" "$env"
  done <<EOF
$(wf '.spec.timers | to_entries[] | [.key, (.value.env // "-")] | @tsv')
EOF
  for class in wait pause; do
    printf 'ladder %s:\n' "$class"
    while IFS=$'\t' read -r rung rungsecs actor; do
      [ -n "$rung" ] || continue
      printf '  %-14s +%ss  to %s\n' "$rung" "$rungsecs" "$actor"
    done <<EOF
$(ladder_rungs "$class")
EOF
    if cadence=$(ladder_realert_secs "$class"); then
      printf '  %-14s every %ss\n' 're-alert' "$cadence"
    else
      printf '  %-14s %s\n' 're-alert' 'not in this definition'
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# timers
# ---------------------------------------------------------------------------
cmd_timers() {
  local rows name value env
  rows=$(wf '.spec.timers | to_entries[] | [.key, (.value.seconds | tostring), (.value.env // "")] | @tsv' 2>/dev/null) \
    || die 'the definition carries no timers'
  while IFS=$'\t' read -r name value env; do
    [ -n "$name" ] || continue
    value=$(timer_resolve "$name" "$env" "$value") || exit $?
    printf '%s\t%s\n' "$name" "$value"
  done <<EOF
$rows
EOF
  return 0
}

# ---------------------------------------------------------------------------
# tick - the live rung
# ---------------------------------------------------------------------------
# Deliver one rung's wake exactly as the ladder code delivered it: the same wake
# line, the same <key>-<rung> queue key, and the same episode stamp afterwards so
# the rungs this definition does not carry yet keep their timing from it.
# What a tick needs from the definition, in ONE jq read rather than one per field:
# each wait source as the ladder table row (<name><TAB><lapse rule>), each
# ladder's single owner timer, and every timer's env name and seconds. Fields are
# split by \037, so an empty field stays a field. Fails, as the per-field reads
# did, when the definition carries no wait source.
tick_plan() {
  jq -r '.spec as $s
    | ([$s.sources[] | select(.facts == "wait-source")] | if length == 0 then error("no wait source") else . end) as $src
    | ($src[] | "source\u001f" + ([.name, (if .lapse then .lapse elif .fresh then "fresh" else "any" end)] | @tsv)),
      (("wait", "pause") as $c | [$s.ladders[$c].rungs[]? | select(.rung == "owner") | .timer]
        | select(length == 1 and .[0] != null and .[0] != false) | "owner\u001f" + $c + "\u001f" + (.[0] | tostring)),
      (($s.timers // {}) | to_entries[]
        | select(.value.env != null and .value.env != false and .value.seconds != null and .value.seconds != false)
        | "timer\u001f" + .key + "\u001f" + (.value.env | tostring) + "\u001f" + (.value.seconds | tostring))' "$DEF"
}

# timer_secs, read from the tick's plan (WF_PLAN_TIMERS) instead of the definition.
plan_timer_secs() {  # <timer-name>
  local name env value
  while IFS=$'\037' read -r name env value; do
    [ "$name" = "$1" ] || continue
    timer_resolve "$name" "$env" "$value"
    return
  done <<EOF
$WF_PLAN_TIMERS
EOF
  return 1
}

need_fact_libs() { load_fact_libs || die 'the ladder fact libraries are not in this tree'; }

tick_reason() {  # <task> <key> <since> <verb> <source>
  printf 'check: waiting-state %s (%s, observed %ss, level=owner; %s must recheck and unblock) id=%s source=[%s]' \
    "$1" "$4" "$((WF_NOW - $3))" "$(actor_text)" "$2" "$5"
}

# Escalation optimisation (core/escalation-optimize): the owner wake carries its
# evidence and the one action wanted, and the optimiser decides whether it wakes a
# model now. A home without the feature delivers as before.
OPTIMIZER="$ROOT/core/escalation-optimize/bin/jg-escalation-optimize.sh"
opt_available() { [ -x "$OPTIMIZER" ] && [ -z "${JG_ESCALATION_OPT_OFF:-}" ]; }
opt_envelope() {  # <task> <verb> <since>
  printf ' evidence=[%s declared %s, unchanged for %ss] action=[recheck %s and unblock it or declare why it waits]' \
    "$1" "$2" "$((WF_NOW - $3))" "$1"
}

cmd_tick() {
  local dir="$STATE/.waiting-timers" now record task sig since owner key
  local wait_secs pause_secs class _src window decl verb source rungsecs reason wait_state
  local _sig _owner _parent misses _card _last rows name rule plan kind a b c owner_wait='' owner_pause=''
  [ -d "$dir" ] || return 0
  if opt_available; then
    JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" JG_CONFIG_OVERRIDE="$CONFIG" "$OPTIMIZER" resolve >/dev/null 2>&1 || true
    # Held rows leave as one wake per group, with a one-line digest.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      need_fact_libs
      jg_wake_append check "escalation-digest-$(printf '%s' "$line" | awk '{ print $3 }')" "$line" || return 1
    done <<DIGEST_END
$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" JG_CONFIG_OVERRIDE="$CONFIG" "$OPTIMIZER" flush 2>/dev/null)
DIGEST_END
  fi
  # The wait-source table is read once per tick, not once per lane, with each
  # named lapse timer resolved to its seconds.
  plan=$(tick_plan) || return 1
  rows='' WF_PLAN_TIMERS=''
  while IFS=$'\037' read -r kind a b c; do
    case "$kind" in
      source) rows="$rows$a"$'\n' ;;
      owner) if [ "$a" = wait ]; then owner_wait=$b; else owner_pause=$b; fi ;;
      timer) WF_PLAN_TIMERS="$WF_PLAN_TIMERS$a"$'\037'"$b"$'\037'"$c"$'\n' ;;
    esac
  done <<EOF
$plan
EOF
  WF_SOURCES=''
  while IFS=$'\t' read -r name rule; do
    [ -n "$name" ] || continue
    case "$rule" in any | fresh) ;; *) rule=$(plan_timer_secs "$rule") || return 1 ;; esac
    WF_SOURCES="$WF_SOURCES$(printf '%s\t%s' "$name" "$rule")
"
  done <<EOF
$rows
EOF
  wait_secs='' pause_secs=''
  [ -z "$owner_wait" ] || wait_secs=$(plan_timer_secs "$owner_wait" 2>/dev/null) || wait_secs=''
  [ -z "$owner_pause" ] || pause_secs=$(plan_timer_secs "$owner_pause" 2>/dev/null) || pause_secs=''
  [ -n "$wait_secs$pause_secs" ] || return 0
  now=$(date +%s) || return 1
  WF_NOW=$now
  for record in "$dir"/*; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    task=${record##*/}
    IFS=$'\t' read -r sig since owner _parent key misses _card _last <"$record" || continue
    case "$since" in '' | *[!0-9]*) continue ;; esac
    # A miss is a poll that saw the lane out of its wait: the timers keep its clock for one
    # flicker, and the owner rung waits for a poll that still sees the wait.
    [ "${misses:-0}" = 0 ] || continue
    # The ladder normalizes a legacy owner level of 1 to "no owner delivery yet".
    case "${owner:-0}" in 0 | 1) ;; *) continue ;; esac
    [ -n "$key" ] || continue
    need_fact_libs
    class='wait'
    if facts=$(wf_facts "$task"); then
      IFS=$'\t' read -r class _src window decl verb <<<"$facts"
      source=$(printf '%s' "$decl" | tr '\t\n' '  ' | cut -c1-160)
      rungsecs=$wait_secs
      [ "$class" != pause ] || rungsecs=$pause_secs
      if [ "$class" = pause ]; then
        wait_state=$(jg_wait_machine_state "$SCRIPT_DIR" "$task") || return 1
        [ "$wait_state" != paused-no-date ] || rungsecs=$JG_WAIT_PLACEHOLDER_SECS
      fi
    else
      # A lane the runtime reported blocked has no recorded declaration this fact
      # layer can read (the definition names that source `herdr-blocked`); its
      # episode key still names the source, and it rides the wait ladder.
      case "$key" in
        *-herdr-blocked) verb=herdr-blocked source=herdr-blocked rungsecs=$wait_secs ;;
        *) continue ;;
      esac
    fi
    [ -n "$rungsecs" ] || continue
    [ "$now" -ge "$((since + rungsecs))" ] || continue
    reason=$(tick_reason "$task" "$key" "$since" "$verb" "$source")
    if opt_available; then
      reason="$reason$(opt_envelope "$task" "$verb" "$since")"
      case "$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" JG_CONFIG_OVERRIDE="$CONFIG" \
        "$OPTIMIZER" decide check "$key-owner" "$reason" "$task" "$now")" in
        deliver*) ;;
        *) continue ;;
      esac
    fi
    if ! jg_wake_queued_keys check | grep -Fx "$key-owner" >/dev/null; then
      jg_wake_append check "$key-owner" "$reason" || return 1
    fi
    printf '%s\t%s\t%s\t0\t%s\t0\t0\t0\n' "$sig" "$since" "$now" "$key" >"$record.tmp.$$" \
      && mv "$record.tmp.$$" "$record" || return 1
    printf '%s\n' "$reason"
    return 0  # one wake per poll, as the ladder's own owner fire was
  done
  return 0
}

# The fact layer, shared with the ladder code: the same hash, status-fold and
# metadata readers decide what a lane's wait is.
load_fact_libs() {
  [ -z "${WF_FACT_LIBS:-}" ] || return 0
  WF_FACT_LIBS=1
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-wake-lib.sh" || return 1
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-classify-lib.sh" || return 1
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-backend.sh" || return 1
  # The portable mtime read the watcher uses, and its age rule.
  if [ "$(uname)" = Darwin ]; then
    stat_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
  else
    stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  fi
  age_of() {
    local m now
    m=$(stat_mtime "$1") || { echo 999999; return; }
    now=$(date +%s) || { echo 999999; return; }
    [ "$m" -le "$now" ] || { echo 999999; return; }
    echo $(( now - m ))
  }
  # A captain hold waits on the captain, so a held lane never arms an episode.
  JG_PUSH_TRANSITION_LIB_DIR=$ROOT/bin
  export JG_PUSH_TRANSITION_LIB_DIR
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-push-transition-lib.sh" 2>/dev/null || task_captain_call_open() { return 1; }
  return 0
}

main() {
  local cmd=${1:-}
  shift || true
  command -v jq >/dev/null 2>&1 || die 'jq is required to read the definition'
  DEF=$(definition) || die 'no escalation workflow definition found'
  case "$cmd" in
    show) cmd_show "$@" ;;
    timers) cmd_timers "$@" ;;
    tick)
      # The fact libraries load at the first episode or digest a tick finds, so a
      # poll with no open episode does not pay for them.
      cmd_tick "$@"
      ;;
    *) die 'usage: jg-escalation-workflows.sh show | timers | tick' ;;
  esac
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
