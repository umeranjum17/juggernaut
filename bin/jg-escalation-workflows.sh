#!/usr/bin/env bash
# jg-escalation-workflows.sh - a stuck lane's wait timers as one declarative
# workflow definition, running in SHADOW beside the timer code that stays
# authoritative.
#
# WHY THIS EXISTS (migration step 5c, first half: the wait timers). The timer is
# shell today: the owner alert threshold, the pause cadence and the wait-source
# priority are rebuilt by hand inside core/wait-timers/bin/jg-wait-timers-lib.sh,
# and procevent, ask-default, lead-wake, fleet-stall, nm-drain and merge-on-green
# each carry their own copy of the same shape. The decided shape is one workflow
# definition with timers and external events, so a new threshold is a config line
# plus a test and never a core code change. This step puts that definition beside
# the code and proves it fires at the same time for the same wait. NOTHING
# SWITCHES: bin/jg-watch.sh keeps running jg_wait_timers_tick, and this script
# writes nothing into the file path it reads.
#
# CONTRACT (this header is the one owner of the timer's shape).
#   definition  core/bus/workflows/escalation-wait-timers.json, overridable per home
#               at config/escalation-workflows.json or by JG_ESCALATION_WORKFLOW.
#               It owns the rungs, which timer each rung fires on, each timer's
#               seconds and the environment name it answers to, the ladder a wait
#               class uses, the wait-source priority and the episode key template.
#               The Dapr side of the same definition is
#               core/bus/dapr/resiliency.yaml.
#               This half carries two timers: the owner alert at
#               JG_WAIT_ALERT_SECS (120s) for a lane in a declared wait, and the
#               pause cadence at JG_PAUSE_RESURFACE_SECS (14400s) for a lane in a
#               declared pause. The escalation rungs and the re-alert cadence are
#               the second half of the same definition, and this script's parity
#               compares only the rungs the definition in force carries.
#   facts       The one thing the definition does not own is how a fact is read:
#               a status log, a wait source, the pause-until token and the captain
#               hold are read with the same shared libraries the ladder code reads
#               them with (bin/jg-classify-lib.sh, bin/jg-wake-lib.sh,
#               bin/jg-backend.sh). Facts are gathered, policy decides.
#   show        Print the definition in force with every timer's effective value,
#               so a drift between the shell default and the definition is visible
#               without running anything.
#   tick        The shadow. Once per watcher poll, for every open authoritative
#               episode, append the rungs the definition says should already have
#               fired to $STATE/escalation-workflows.jsonl, marked with the time
#               the authoritative record shows it fired (0 while it has not). A
#               home turns it on with config/escalation-workflows, the same way
#               config/wake-bus turns the wake mirror on. Off costs one file test,
#               and a shadow that cannot read its definition never fails or
#               delays a poll.
#   parity      Replay recorded ladder events through both paths and compare one
#               row per rung the definition carries: <key> <rung> <epoch>. The
#               current path is the real jg_wait_timers_tick, driven on a replayed
#               clock with its delivery stubbed; the new path is this definition's
#               engine over the same replayed facts. A plain diff decides.
#               `--corrupt` shifts the arming time of one replayed event on the
#               new path only, which must produce a difference, so a green replay
#               is never vacuous.
#
# Usage:
#   jg-escalation-workflows.sh show
#   jg-escalation-workflows.sh tick
#   jg-escalation-workflows.sh parity [--home DIR] [--days N] [--corrupt]
set -u
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
CONFIG=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}

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
# default that drifted apart shows up as a parity difference rather than as a
# second copy of the number here.
timer_secs() {  # <timer-name>
  local name=$1 env value
  env=$(wf ".spec.timers[\"$name\"].env // empty") || return 1
  value=$(wf ".spec.timers[\"$name\"].seconds // empty") || return 1
  if [ -n "$env" ] && [ -n "${!env:-}" ]; then value=${!env}; fi
  case "$value" in
    '' | *[!0-9]* | 0*) die "timer $name is not positive decimal seconds: ${value:-<empty>}" ;;
  esac
  printf '%s' "$value"
}

actor_role() {
  if [ -e "$JG_HOME/.jg-squad-lead-home" ]; then printf 'lead'; else printf 'main'; fi
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

# Rungs a lane re-delivers on every re-alert while its wait stays open: the
# board card is re-posted under the same key, so one card stays on the board.
ladder_redeliver() {  # <wait|pause>
  jq -er --arg c "$1" '.spec as $s
    | $s.ladders[$c].rungs[]?
    | .rung as $r
    | select($s.rungs[$r].repeats == true)
    | $r' "$DEF" 2>/dev/null || true
}

# Every rung this definition carries, across both ladders, plus the re-alert
# cadence when a ladder declares one. The parity compares only these, so each
# half of the migration proves exactly the rungs it defines.
modelled_rungs() {
  local class
  for class in wait pause; do
    ladder_rungs "$class" | cut -f1
    ladder_realert_secs "$class" >/dev/null 2>&1 && printf 're-alert\n'
  done | LC_ALL=C sort -u
}

# filter_rows <rows>: the rows whose rung this definition carries.
filter_rows() {  # <rows>
  local rungs
  rungs=$(modelled_rungs) || return 1
  awk -F '\t' -v want="$(printf '%s' "$rungs" | tr '\n' ' ')" '
    BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) keep[w[i]] = 1 }
    ($2 in keep)' "$1"
}

ladder_realert_secs() {  # <wait|pause>
  local timer
  timer=$(wf ".spec.ladders[\"$1\"][\"re-alert\"] // empty") || return 1
  [ -n "$timer" ] || return 1
  timer_secs "$timer"
}

# The episode key, from the definition's template. hash_pane is the shared hash
# every record in the fleet already uses; the source slug rule is the ladder's.
wf_key() {  # <task> <generation> <source>
  local tpl home src
  home=$(printf '%s' "$JG_HOME" | "${WF_HASH_PANE:-hash_pane}")
  home=${home:0:8}
  src=$(printf '%s' "${3:-unkeyed}" | tr -c 'A-Za-z0-9._-' '_')
  src=${src:0:48}
  tpl=$(wf '.spec.key')
  tpl=${tpl//\{home\}/$home}
  tpl=${tpl//\{task\}/$1}
  tpl=${tpl//\{generation\}/$2}
  tpl=${tpl//\{source\}/$src}
  printf '%s' "$tpl"
}

# ---------------------------------------------------------------------------
# The facts. Gathered as the ladder code gathers them; the definition decides
# what to do with them. Prints <class> <source> <window> <declaration>, or
# nothing when the lane is in no wait.
# ---------------------------------------------------------------------------
wf_facts() {  # <task>
  local task=$1 meta="$STATE/$1.meta" window decl='' src='' dkey='' rows
  local until name rule record old verb native fresh
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  window=$(jg_backend_target_of_meta "$meta")
  fresh=$(( ${POLL:-15} * 3 + 30 ))
  while read -r name rule; do
    record="$STATE/.wait-sources/$task.$name"
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    [ "$rule" = any ] || [ "$(age_of "$record")" -lt "$fresh" ] || continue
    decl=$(head -n 1 "$record" | tr '\t' ' ' | cut -c1-300)
    src=$name
    [ -z "$decl" ] || break
  done <<EOF
$(wf '.spec.sources[] | select(.facts == "wait-source") | [.name, (if .fresh then "fresh" else "any" end)] | @tsv')
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
  if status_is_paused "$decl" && until=$(status_paused_until "$decl") && [ "$WF_NOW" -lt "$until" ]; then
    decl=''
  fi
  if [ -n "$decl" ] && declare -F task_captain_call_open >/dev/null && task_captain_call_open "$task"; then
    decl=''
  fi
  [ -n "$decl" ] || return 1
  if status_is_paused "$decl"; then
    src=$(_jg_decision_key "$decl") || src=default
    printf 'pause\t%s\t%s\t%s\n' "$src" "$window" "$decl"
  else
    printf 'wait\t%s\t%s\t%s\n' "${dkey:-$src}" "$window" "$decl"
  fi
}

wf_signature() {  # <class> <window> <declaration>
  local key
  if [ "$1" = pause ]; then
    key=$(_jg_decision_key "$3") || key=default
    printf '%s|%s|%s' "$2" "$(status_line_verb "$3")" "$key" | "${WF_HASH_PANE:-hash_pane}"
  else
    printf '%s|%s' "$2" "$3" | "${WF_HASH_PANE:-hash_pane}"
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
      printf '  %-14s %s\n' 're-alert' 'not in this half'
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# tick - the live shadow
# ---------------------------------------------------------------------------
cmd_tick() {
  local dir="$STATE/.waiting-timers" out="$STATE/escalation-workflows.jsonl" now
  local record task since owner parent card key last facts class src window decl
  local rung rungsecs actor scheduled recorded
  [ -e "$CONFIG/escalation-workflows" ] || return 0
  [ -d "$dir" ] || return 0
  now=$(date +%s) || return 1
  for record in "$dir"/*; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    task=${record##*/}
    IFS=$'\t' read -r _sig since owner parent key _misses card last <"$record" || continue
    case "$since" in '' | *[!0-9]*) continue ;; esac
    facts=$(wf_facts "$task") || continue
    IFS=$'\t' read -r class src window decl <<<"$facts"
    while IFS=$'\t' read -r rung rungsecs actor; do
      [ -n "$rung" ] || continue
      [ "$actor" = '*' ] || [ "$actor" = "$(actor_role)" ] || continue
      scheduled=$((since + rungsecs))
      [ "$scheduled" -le "$now" ] || continue
      case "$rung" in
        owner) recorded=${owner:-0} ;;
        escalate) recorded=${parent:-0} ;;
        card) recorded=${card:-0} ;;
        re-alert) recorded=${last:-0} ;;
        *) recorded=0 ;;
      esac
      grep -Fq "\"key\":\"$key\",\"rung\":\"$rung\"" "$out" 2>/dev/null && continue
      printf '{"at":%s,"task":"%s","key":"%s","rung":"%s","ladder":"%s","scheduled":%s,"recorded":%s}\n' \
        "$now" "$task" "$key" "$rung" "$class" "$scheduled" "${recorded:-0}" >>"$out" || return 1
    done <<EOF
$(ladder_rungs "$class")
EOF
  done
  return 0
}

# ---------------------------------------------------------------------------
# parity - the replay
# ---------------------------------------------------------------------------
# The current path's delivery, stubbed: every rung it fires is one row, and the
# episode bookkeeping the real wake does after a delivered output is kept, so the
# ladder's own state machine runs unchanged. A stub never exits the replayed
# cycle, so every lane is evaluated at each instant.
cur_install() {
  wake() {
    # The real wake exits its cycle, so the post-output action it fires belongs to
    # this fire only; clearing it here keeps a replayed cycle from applying a stale
    # one to a later rung, which would rewrite the episode it just fired.
    local action=${JG_WAKE_POST_OUTPUT_ACTION:-}
    JG_WAKE_POST_OUTPUT_ACTION=''
    [ -z "$action" ] || "$action" 0 || true
    return 0
  }
  jg_wake_append() {  # <kind> <key> <payload>
    local key=$2 rung
    case "$key" in
      *-owner-again | *-main-again) rung=re-alert; key=${key%-owner-again}; key=${key%-main-again} ;;
      *-owner) rung=owner; key=${key%-owner} ;;
      *-escalation) rung=escalate; key=${key%-escalation} ;;
      *) return 0 ;;
    esac
    printf '%s\t%s\t%s\n' "$key" "$rung" "$WF_NOW" >>"$CUR_ROWS"
  }
  jg_wake_queued_keys() { :; }
  jg_wait_timer_card() { printf '%s\tcard\t%s\n' "${2%-card}" "$WF_NOW" >>"$CUR_ROWS"; }
  jg_wait_timer_report() {
    local key
    case "$1" in *waiting-timer-overdue:*) ;; *) return 0 ;; esac
    key=$(printf '%s' "$1" | sed -n 's/.*\[key=\([A-Za-z0-9._-]*\)\].*/\1/p')
    [ -n "$key" ] || return 0
    printf '%s\tescalate\t%s\n' "$key" "$WF_NOW" >>"$CUR_ROWS"
  }
}

# The authoritative ladder, run for one replayed instant. Its own libraries and
# its own state machine; only delivery and the clock are stand-ins.
cur_step() {
  local rc=0
  jg_wait_timers_tick 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || say "parity: the ladder tick failed at $WF_NOW (code $rc); its rows stop there"
  return 0
}

# The definition's engine: one row per rung the definition says fires, at the
# instant it says so. Its episodes are its own; it reads only the facts.
wf_step() {  # <now>
  local now=$1 meta task facts class src window decl sig rec
  local cur_sig cur_class cur_since cur_key fired rung rungsecs actor cadence base
  for meta in "$REPLAY_STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    rec="$WF_EPI/$task"
    if ! facts=$(wf_facts "$task"); then
      rm -f "$rec"
      continue
    fi
    IFS=$'\t' read -r class src window decl <<<"$facts"
    sig=$(wf_signature "$class" "$window" "$decl")
    cur_sig=''
    cur_class=''
    cur_since=''
    cur_key=''
    fired=''
    if [ -f "$rec" ] && [ ! -L "$rec" ]; then
      IFS=$'\t' read -r cur_sig cur_class cur_since cur_key fired <"$rec" || true
    fi
    if [ "$cur_sig" != "$sig" ] || [ "$cur_class" != "$class" ]; then
      cur_since=$now
      if [ -n "${WF_CORRUPT_SINCE:-}" ] && [ "$cur_since" = "$WF_CORRUPT_SINCE" ]; then
        cur_since=$((cur_since + 1))
      fi
      cur_key=$(wf_key "$task" "$cur_since" "$src")
      fired=''
      cur_sig=$sig
      cur_class=$class
    fi
    while IFS=$'\t' read -r rung rungsecs actor; do
      [ -n "$rung" ] || continue
      [ "$actor" = '*' ] || [ "$actor" = "$(actor_role)" ] || continue
      [ "$(fired_get "$fired" "$rung")" = 0 ] || continue
      if [ "$now" -ge "$((cur_since + rungsecs))" ]; then
        printf '%s\t%s\t%s\n' "$cur_key" "$rung" "$((cur_since + rungsecs))" >>"$WF_ROWS"
        printf '%s\n' "$cur_since" >>"$WF_SINCE"
        fired=$(fired_set "$fired" "$rung" "$((cur_since + rungsecs))")
      else
        next_add "$((cur_since + rungsecs))"
      fi
    done <<EOF
$(ladder_rungs "$class")
EOF
    cadence=$(ladder_realert_secs "$class" 2>/dev/null) || cadence=''
    if [ -n "$cadence" ] && [ "$(fired_get "$fired" owner)" -gt 0 ]; then
      base=$(fired_max "$fired")
      if [ "$now" -ge "$((base + cadence))" ]; then
        # A rung that repeats is re-delivered with every re-alert, exactly as the
        # current code re-posts the board card while the wait stays open.
        while IFS= read -r rung; do
          [ -n "$rung" ] || continue
          [ "$(fired_get "$fired" "$rung")" -gt 0 ] || continue
          printf '%s\t%s\t%s\n' "$cur_key" "$rung" "$now" >>"$WF_ROWS"
        done <<EOF2
$(ladder_redeliver "$class")
EOF2
        printf '%s\t%s\t%s\n' "$cur_key" 're-alert' "$now" >>"$WF_ROWS"
        printf '%s\n' "$cur_since" >>"$WF_SINCE"
        fired=$(fired_set "$fired" 're-alert' "$now")
      else
        next_add "$((base + cadence))"
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$sig" "$class" "$cur_since" "$cur_key" "$fired" >"$rec.tmp.$$" \
      && mv "$rec.tmp.$$" "$rec" || return 1
  done
  return 0
}

# Fired-rung bookkeeping: one "name:epoch" token per fired rung.
fired_get() {  # <fired> <rung> -> epoch or 0
  local token
  for token in $1; do
    [ "${token%%:*}" != "$2" ] || { printf '%s' "${token#*:}"; return 0; }
  done
  printf '0'
}

fired_set() {  # <fired> <rung> <epoch> -> the new set
  local token out=''
  for token in $1; do
    [ "${token%%:*}" != "$2" ] || continue
    out="$out $token"
  done
  printf '%s %s:%s' "${out# }" "$2" "$3" | sed 's/^ //'
}

fired_max() {  # <fired> -> the greatest epoch in the set
  local token max=0
  for token in $1; do
    [ "${token#*:}" -le "$max" ] || max=${token#*:}
  done
  printf '%s' "$max"
}

next_add() {  # <epoch>: the next instant this replay must look at
  [ "$1" -gt "$WF_NOW" ] || return 0
  if [ -z "$WF_NEXT" ] || [ "$1" -lt "$WF_NEXT" ]; then WF_NEXT=$1; fi
  return 0
}

# Recorded ladder events, one per line: <epoch> <kind> <task> <payload>. A status
# line is an event at its own [at=] stamp; a wait source is the sighting its
# mtime records. Nothing is inferred that the record does not carry.
collect_events() {  # <state-dir> <since> <out>
  local state=$1 since=$2 out=$3 f line epoch task src name
  : >"$out"
  for f in "$state"/*.status; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    task=${f##*/}
    task=${task%.status}
    while IFS= read -r line; do
      epoch=$(printf '%s' "$line" | sed -n 's/.*\[at=\([0-9]\{9,12\}\)\].*/\1/p')
      [ -n "$epoch" ] || continue
      [ "$epoch" -ge "$since" ] || continue
      printf '%s\tstatus\t%s\t%s\n' "$epoch" "$task" "$line" >>"$out"
    done <"$f"
  done
  for f in "$state"/.wait-sources/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    name=${f##*/}
    task=${name%.*}
    epoch=$(stat_mtime "$f") || continue
    [ -n "$epoch" ] || continue
    [ "$epoch" -ge "$since" ] || continue
    printf '%s\tsource\t%s\t%s\n' "$epoch" "$task" "${name##*.}" >>"$out"
  done
  LC_ALL=C sort -n -k1,1 "$out" -o "$out"
}

# Replay the events up to <upto> into the replay home.
apply_events() {  # <upto>
  local upto=$1 epoch kind task payload n=0 file
  while IFS=$'\t' read -r epoch kind task payload; do
    n=$((n + 1))
    [ "$n" -gt "${APPLIED:-0}" ] || continue
    [ "$epoch" -le "$upto" ] || break
    case "$kind" in
      status) printf '%s\n' "$payload" >>"$REPLAY_STATE/$task.status" ;;
      source)
        file="$REPLAY_STATE/.wait-sources/$task.$payload"
        [ ! -f "$REC_STATE/.wait-sources/$task.$payload" ] \
          || cp -f "$REC_STATE/.wait-sources/$task.$payload" "$file"
        [ ! -f "$file" ] || touch -d "@$epoch" "$file" 2>/dev/null || true
        ;;
    esac
    APPLIED=$n
  done <"$EVENTS"
  return 0
}

# One snapshot of what the records carry, taken once per run so both passes read
# the same bytes even while the recorded home keeps working beside them. A lane's
# endpoint is made inert here: a replayed lane has no live pane, and no recorded
# fact says whether the runtime held it blocked.
snapshot_state() {  # <recorded-state> <dest>
  local rec=$1 dest=$2 f name
  mkdir -p "$dest/.wait-sources"
  for f in "$rec"/*.meta; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    name=${f##*/}
    sed 's/^backend=.*/backend=tmux/' "$f" >"$dest/$name"
  done
  for f in "$rec"/*.status; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    cp -p "$f" "$dest/${f##*/}" 2>/dev/null || true
  done
  for f in "$rec"/.wait-sources/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    cp -p "$f" "$dest/.wait-sources/${f##*/}" 2>/dev/null || true
  done
  return 0
}

# A replay home made only of what the snapshot holds: the metadata of every lane
# that has a recorded event. Every pass starts from this same empty home, so two
# passes over one event set differ only by the corruption between them.
reset_replay_home() {
  local task
  rm -rf -- "$REPLAY_HOME"
  mkdir -p "$REPLAY_STATE/.wait-sources" "$REPLAY_STATE/.waiting-timers"
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    [ -f "$REC_STATE/$task.meta" ] || continue
    cp -p "$REC_STATE/$task.meta" "$REPLAY_STATE/$task.meta" || return 1
  done <<EOF
$(awk -F '\t' '{ print $3 }' "$EVENTS" | LC_ALL=C sort -u)
EOF
  return 0
}

# The replay clock: every `date +%s` inside the ladder code answers with the
# replayed instant, and every other date call is the real one, so no record's own
# parsing changes.
make_date_shim() {  # <path>
  local real
  real=$(command -v date) || die 'date not found'
  cat >"$1" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "+%s" ] && [ -n "\${WF_NOW:-}" ]; then printf '%s\\n' "\$WF_NOW"; exit 0; fi
exec $(printf '%q' "$real") "\$@"
SH
  chmod +x "$1"
}

replay() {  # <since> <end> <run-both>
  local since=$1 end=$2 both=$3 step
  APPLIED=0
  STEPS=0
  step=$(awk -F '\t' -v s="$since" '$1 >= s { print $1; exit }' "$EVENTS")
  [ -n "$step" ] || step=$since
  while [ -n "$step" ] && [ "$step" -le "$end" ]; do
    STEPS=$((STEPS + 1))
    WF_NOW=$step
    export WF_NOW
    STATE=$REPLAY_STATE
    JG_HOME=$REPLAY_HOME
    apply_events "$step"
    if [ "$both" -eq 1 ]; then cur_step; fi
    WF_NEXT=''
    wf_step "$step"
    step=$(next_step "$end")
  done
}

next_step() {  # <end>
  local next=$WF_NEXT epoch
  epoch=$(awk -F '\t' -v now="$WF_NOW" '$1 > now { print $1; exit }' "$EVENTS")
  if [ -n "$epoch" ] && { [ -z "$next" ] || [ "$epoch" -lt "$next" ]; }; then next=$epoch; fi
  [ -n "$next" ] && [ "$next" -le "$1" ] || next=''
  printf '%s' "$next"
}

row_diff() {  # <current-rows> <workflow-rows> -> changed line count
  local a=$1 b=$2 out changed
  out=$(mktemp "${TMPDIR:-/tmp}/jg-escalation-diff.XXXXXX") || return 1
  LC_ALL=C sort "$a" >"$out.a"
  LC_ALL=C sort "$b" >"$out.b"
  if ! diff -u "$out.a" "$out.b" >"$out" 2>&1; then
    changed=$(grep -cE '^[+-][^+-]' "$out" || true)
    grep -E '^[+-][^+-]' "$out" | head -n 20 >&2
  else
    changed=0
  fi
  rm -f "$out" "$out.a" "$out.b"
  printf '%s' "${changed:-0}"
}

cmd_parity() {
  local home=$JG_HOME days=7 since end corrupt=0 diffcount compared rungs dir corrupt_since=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) home=${2:-}; shift 2 || die '--home needs a directory' ;;
      --days) days=${2:-}; shift 2 || die '--days needs a number' ;;
      --corrupt) corrupt=1; shift ;;
      *) die "parity: unknown argument $1" ;;
    esac
  done
  case "$days" in '' | *[!0-9]* | 0*) die '--days must be positive decimal days' ;; esac
  [ -d "$home/state" ] || die "no state directory under $home"
  [ -r "$ROOT/core/wait-timers/bin/jg-wait-timers-lib.sh" ] \
    || { printf 'skip: the authoritative ladder library is not in this tree\n'; return 0; }
  end=$(date +%s)
  since=$((end - days * 86400))
  load_ladder_libs || return 1
  dir=$(mktemp -d "${TMPDIR:-/tmp}/jg-escalation-parity.XXXXXX") || return 1
  if [ -n "${JG_ESCALATION_KEEP:-}" ]; then
    say "parity: keeping $dir"
  else
    # shellcheck disable=SC2064 # The trap must see the final value.
    trap "rm -rf -- $(printf '%q' "$dir")" EXIT
  fi
  EVENTS=$dir/events
  CUR_ROWS=$dir/current.rows
  WF_ROWS=$dir/workflow.rows
  WF_SINCE=$dir/workflow.since
  WF_EPI=$dir/workflow.episodes
  REC_STATE=$dir/recorded
  REPLAY_HOME=$dir/home
  REPLAY_STATE=$REPLAY_HOME/state
  mkdir -p "$dir/bin" "$WF_EPI"
  PATH="$dir/bin:$PATH"
  export PATH
  : >"$CUR_ROWS"
  : >"$WF_ROWS"
  : >"$WF_SINCE"
  make_date_shim "$dir/bin/date"
  snapshot_state "$home/state" "$REC_STATE"
  collect_events "$REC_STATE" "$since" "$EVENTS"
  reset_replay_home
  if [ "$corrupt" -eq 1 ]; then
    # One pass with the current path to know the rows, one pass on the new path
    # alone with a single recorded event's arming time shifted, then the same
    # diff. A shift that produced no difference would mean the check is vacuous.
    replay "$since" "$end" 1
    if [ -s "$WF_SINCE" ]; then
      corrupt_since=$(LC_ALL=C sort -n "$WF_SINCE" | head -n 1)
    fi
    if [ -z "$corrupt_since" ]; then
      printf 'escalation workflow parity --corrupt: no replayed episode fired a rung, so there is nothing to corrupt\n'
      return 1
    fi
    WF_CORRUPT_SINCE=$corrupt_since
    export WF_CORRUPT_SINCE
    WF_EPI=$dir/workflow.episodes.corrupt
    mkdir -p "$WF_EPI"
    WF_ROWS=$dir/workflow.corrupt.rows
    : >"$WF_ROWS"
    : >"$WF_SINCE"
    reset_replay_home
    replay "$since" "$end" 0
    compared=$(awk 'END { print NR }' "$EVENTS")
    filter_rows "$CUR_ROWS" >"$dir/current.modelled"
    filter_rows "$WF_ROWS" >"$dir/workflow.modelled"
    rungs=$(awk 'END { print NR }' "$dir/current.modelled")
    diffcount=$(row_diff "$dir/current.modelled" "$dir/workflow.modelled")
    printf 'escalation workflow parity --corrupt: shifted the arming time of the recorded event at %s by 1s on the new path: events=%s rungs=%s steps=%s differences=%s (must be non-zero)\n' \
      "$corrupt_since" "$compared" "$rungs" "$STEPS" "$diffcount"
    [ "$diffcount" -ne 0 ]
    return
  fi
  replay "$since" "$end" 1
  compared=$(awk 'END { print NR }' "$EVENTS")
  filter_rows "$CUR_ROWS" >"$dir/current.modelled"
  filter_rows "$WF_ROWS" >"$dir/workflow.modelled"
  rungs=$(awk 'END { print NR }' "$dir/current.modelled")
  diffcount=$(row_diff "$dir/current.modelled" "$dir/workflow.modelled")
  printf 'escalation workflow parity: home=%s window=%sd events=%s rungs=%s steps=%s differences=%s\n' \
    "$home" "$days" "$compared" "$rungs" "$STEPS" "$diffcount"
  [ "$diffcount" -eq 0 ]
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
  WF_HASH_PANE=hash_pane
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

load_ladder_libs() {
  local W="$ROOT/core/wait-timers/bin/jg-wait-timers-lib.sh"
  [ -r "$W" ] || return 1
  load_fact_libs || return 1
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-timeout-lib.sh" || return 1
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-parent-channel-lib.sh" || return 1
  # The replayed clock in place of the wall clock, so a day of ladder history
  # replays at its own instants instead of today's.
  age_of() {
    local m
    m=$(stat_mtime "$1") || { echo 999999; return; }
    [ "$m" -le "$WF_NOW" ] || { echo 999999; return; }
    echo $(( WF_NOW - m ))
  }
  # A replayed home carries no backlog, so it records no captain hold to read.
  task_captain_call_open() { return 1; }
  # shellcheck source=/dev/null
  . "$W" || return 1
  cur_install
  return 0
}

main() {
  local cmd=${1:-}
  shift || true
  DEF=$(definition) || die 'no escalation workflow definition found'
  command -v jq >/dev/null 2>&1 || die 'jq is required to read the definition'
  if [ "$cmd" != show ]; then load_fact_libs || die 'the ladder fact libraries are not in this tree'; fi
  case "$cmd" in
    show) cmd_show "$@" ;;
    tick) cmd_tick "$@" ;;
    parity) cmd_parity "$@" ;;
    *) die 'usage: jg-escalation-workflows.sh show | tick | parity [--home DIR] [--days N] [--corrupt]' ;;
  esac
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
