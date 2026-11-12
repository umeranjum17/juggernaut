#!/usr/bin/env bash
# Waiting-state timers, called once per jg-watch.sh poll, independent of pane
# churn, busy proofs, and stale/wedge suppression. This is the stuck-worker
# escalation chain; core/wait-timers/README.md owns its rungs, thresholds and
# record format. The owner alert and the pause cadence are no longer here: the
# escalation workflow definition decides and delivers those two rungs
# (bin/jg-escalation-workflows.sh, live), and this file keeps the rungs the
# definition does not carry yet - the escalation to Main, the board card and the
# re-alert cadence - riding the owner time the definition stamps.
# Each recorded task owns one durable episode under state/.waiting-timers/.
# A home with a pause record (bin/jg-pause-lib.sh, the one owner) silences its
# stalled ready backlog as well: no episode, no escalation, and the clock starts
# again when the pause lifts. A paused wait is not a climbing wait.
# The effective declaration is, first to last: admitted Herdr agent.list
# blocked (recorded panes only, Cursor excluded), an unanswered permission
# prompt, a Squad Lead whose own supervision is not running, or a green PR left
# unmerged under yolo (wait sources under state/.wait-sources/, written by
# jg-watch.sh and jg_wait_timers_green_pr), an own open
# blocker/decision, then a declared pause.
# Time starts at first observation and survives watcher restarts.
# Changing state/declaration/endpoint clears and re-arms the episode; a paused
# episode instead keys on window, verb and phase key, so reason-text churn on
# the same pause re-arms nothing. A paused wait rechecks at the
# JG_PAUSE_RESURFACE_SECS cadence, never the owner-alert threshold, and never
# escalates. Every other rung, once reached, fires again every
# JG_PROMPT_REALERT_SECS while the wait stays open, and a new supervisor session
# re-presents every open wait on its first tick.
# An unresolved wait re-fires at every due recheck until its source clears.
# Queue acknowledgement is not handling. Expected pauses retain the change gate
# and its bounded backstop; unchanged pauses are logged without another wake.
# Parent reports use the existing local/remote parent channel. Only the main
# home posts a board card, so only what Main cannot settle reaches the captain.
# An episode key is waiting-timer-<home>-<task>-g<generation>-<source key>, so a
# resolution names exactly one wait and every report prints its unresolved source.
# A waiting-timer-* key belongs to this library; it resolves that report when
# the episode ends.
# Source through jg-watch.sh; the wake library supplies hashing and wake emission.

# Sibling libraries live in the fork's bin/, not beside this feature file.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

_JG_WAIT_TIMER_DIR="${SCRIPT_DIR:-${JG_PUSH_TRANSITION_LIB_DIR:-$JG_HOME/bin}}"
# shellcheck source=bin/jg-parent-channel-lib.sh
. "$_JG_WAIT_TIMER_DIR/jg-parent-channel-lib.sh"
# shellcheck source=bin/jg-timeout-lib.sh
. "$_JG_WAIT_TIMER_DIR/jg-timeout-lib.sh"
# The pause record has one owner (bin/jg-pause-lib.sh): a paused home's ready
# backlog is not a stall.
# shellcheck source=bin/jg-pause-lib.sh
[ ! -r "$_JG_WAIT_TIMER_DIR/jg-pause-lib.sh" ] || . "$_JG_WAIT_TIMER_DIR/jg-pause-lib.sh"
# The known next steps the ladder takes itself live beside this file.
# shellcheck source=core/wait-timers/bin/jg-wait-actions-lib.sh
. "${BASH_SOURCE[0]%/*}/jg-wait-actions-lib.sh"
# shellcheck source=core/wait-timers/bin/jg-wait-policy-lib.sh
. "${BASH_SOURCE[0]%/*}/jg-wait-policy-lib.sh"

# A wait whose owner is already known is quiet: it arms no episode, so no timer
# wake, no escalation and no board card come from it. Three cases only:
#   - a pause parked to the placeholder date (wait machine state paused-no-date):
#     the lane named no real time, so a recheck every 30 minutes only repeats the
#     parking; whoever parked it holds the next step;
#   - a finished lane (its last status line is `done`) whose open decision is for
#     its owner: no worker is left to unblock it, and the owner's card carries the
#     call;
#   - a lane whose open blocker says `waits-for: <ticket>` while that ticket's own
#     lane still runs: the ticket's landing resumes it by itself
#     (jg-wait-actions-lib.sh), and once that lane is gone without landing the
#     wait rings again.
# A wait source (prompt, quota, silence ...), a blocked or needs-decision lane that
# is still working, and a pause with a real date keep their rungs.
jg_wait_timer_quiet() {  # <task> <wait-state> <wait-source>
  [ "$2" != paused-no-date ] || return 0
  [ -z "$3" ] || return 1
  [ "$(status_line_verb "$(last_status_line "$STATE/$1.status")")" != "done" ] || return 0
  jg_wait_action_awaiting "$1"
}

jg_wait_timer_save() {  # <record> <signature> <since> <owner> <parent> <key> <misses> [card] [last]
  local file=$1 temp="${1%/*}/.${1##*/}.tmp.$$"
  shift
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "${7:-0}" "${8:-0}" > "$temp" && mv "$temp" "$file"
}

# Stable episode identity: home, task, generation (the arming second) and the
# source key, so a resolution matches only the wait it names and an unrelated
# open decision or a re-armed episode never shares a key.
jg_wait_timer_key() {  # <task> <generation> <source-key>
  local home src
  home=$(printf '%s' "$JG_HOME" | hash_pane) || return 1
  src=$(printf '%s' "${3:-unkeyed}" | tr -c 'A-Za-z0-9._-' '_')
  printf 'waiting-timer-%s-%s-g%s-%s' "${home:0:8}" "$1" "$2" "${src:0:48}"
}

jg_wait_timer_report() {  # <status-line>
  local rc=0
  jg_parent_channel_report "$JG_HOME" "$STATE" "$1" || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "waiting timers: parent channel publication failed (code $rc; inspect identity/binding or destination permissions)" >&2
    return 1
  }
}

# Pause re-raise gate (README "Re-raise until the wait is handled"). The sidecar
# state/.waiting-timers/.raised/<task> holds what the last raise said: a
# fingerprint of the wait, when that hop's first raise happened, and whether the
# hop's backstop raise was spent. It lives beside the episode record, not in it,
# so the record layout other readers parse is unchanged.
jg_wait_timer_fingerprint() {  # <hop> <key> <window> <verb> <actor> <declaration> <wsrc> <until>
  # The [at=] stamp moves on every refresh and a silent wait restates its age on
  # every scan; neither is the wait changing.
  local text
  text=$(printf '%s' "$6" | tr '\t\n' '  ' | sed 's/\[at=[0-9]*\]//g')
  [ "$7" != silent ] || text=silent
  printf '%s\n' "$1|$2|$3|$4|$5|$8|$text" | hash_pane
}

jg_wait_timer_raised_save() {  # <task> <fingerprint> <hop-start> <backstop-spent>
  local file="$STATE/.waiting-timers/.raised/$1"
  mkdir -p "${file%/*}" && printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"
}

# Exit 0 raises (wakes), 1 stays silent. A raise that cannot be recorded still
# wakes, so a broken sidecar costs tokens and never a missed wait.
jg_wait_timer_raise_gate() {  # <task> <fingerprint> <hop-start> <longest-interval> <now> <forced>
  local file="$STATE/.waiting-timers/.raised/$1" sfp='' start='' spent=0
  if [ -f "$file" ] && [ ! -L "$file" ]; then IFS=$'\t' read -r sfp start spent < "$file" || sfp=''; fi
  case "$start:$spent" in *[!0-9:]*|:*) sfp='' ;; esac
  # No record: the hop's first raise (the owner rung, or an escalation from before
  # this record existed) already said what the wait says now.
  [ -n "$sfp" ] || { sfp=$2 start=$3 spent=0; }
  if [ "$6" = 1 ] || [ "$sfp" != "$2" ]; then
    jg_wait_timer_raised_save "$1" "$2" "$5" 0 || true
    return 0
  fi
  if [ "$spent" -eq 0 ] && [ $(($5 - start)) -ge "$4" ]; then
    jg_wait_timer_raised_save "$1" "$2" "$start" 1 || true
    return 0
  fi
  jg_wait_timer_raised_save "$1" "$2" "$start" "$spent" || true
  return 1
}

# The durable record of a re-raise that did not wake: when, which wait, which hop.
jg_wait_timer_unchanged_log() {  # <now> <task> <key> <hop> <age>
  local log="$STATE/.waiting-timers/.unchanged.log"
  printf '%s\t%s\t%s\t%s\tunchanged for %ss; not raised\n' "$1" "$2" "$3" "$4" "$5" >> "$log" || return 0
  [ "$(wc -c < "$log" 2>/dev/null || echo 0)" -le 262144 ] \
    || { tail -n 500 "$log" > "$log.tmp.$$" && mv "$log.tmp.$$" "$log"; } || true
}

# An immediate native push wake already told the owner about this blocked pane,
# so the episode records that delivery and the poll timer skips its owner wake.
jg_wait_timer_push_delivered() {  # <task> <window>
  local record="$STATE/.waiting-timers/$1" signature now old since owner parent key misses
  now=$(date +%s) || return 1
  signature=$(printf '%s' "$2|herdr-blocked" | hash_pane)
  if [ -e "$record" ] || [ -L "$record" ]; then
    [ -f "$record" ] && [ ! -L "$record" ] || return 1
    IFS=$'\t' read -r old since owner parent key misses _ _ < "$record" || return 1
    if [ "$old" = "$signature" ]; then
      [ "$owner" -eq 0 ] || return 0
      jg_wait_timer_save "$record" "$signature" "$since" "$now" "$parent" "$key" 0
      return
    fi
    if [ "${parent:-0}" != 0 ] && [ -e "$JG_HOME/.jg-squad-lead-home" ]; then
      jg_wait_timer_report "resolved [key=$key]: waiting-timer-cleared: $1 changed state" || return 0
    fi
  fi
  mkdir -p "$STATE/.waiting-timers" || return 1
  jg_wait_timer_save "$record" "$signature" "$now" "$now" 0 "$(jg_wait_timer_key "$1" "$now" herdr-blocked)" 0
}

# jg-watch.sh already woke this home's supervisor about a wait source it just
# recorded (an unanswered prompt, a lead whose supervision is down), so the
# episode records that owner delivery and its later rungs time from it.
jg_wait_timer_source_delivered() {  # <task> <window> <declaration>
  local record="$STATE/.waiting-timers/$1" signature now old since owner parent key misses
  now=$(date +%s) || return 1
  signature=$(printf '%s' "$2|$3" | hash_pane)
  if [ -f "$record" ] && [ ! -L "$record" ]; then
    IFS=$'\t' read -r old since owner parent key misses _ _ < "$record" || return 1
    if [ "$old" = "$signature" ]; then
      [ "$owner" -eq 0 ] || return 0
      jg_wait_timer_save "$record" "$signature" "$since" "$now" "$parent" "$key" 0
      return
    fi
  fi
  [ ! -L "$record" ] || return 1
  # A different episode on this task is re-armed by the next tick, which also
  # resolves any parent report it still holds.
  [ ! -e "$record" ] || return 0
  mkdir -p "$STATE/.waiting-timers" || return 1
  jg_wait_timer_save "$record" "$signature" "$now" "$now" 0 "$(jg_wait_timer_key "$1" "$now" "${3%%:*}")" 0
}

# Post the board card for a wait Main has not settled; main home only. The text
# is stable for the wait, so posting again keeps the one open card. The board
# refuses an id in a title, so the title names the task in plain words.
jg_wait_timer_card() {  # <task> <card-key> <verb> <source> [title] [why]
  local words why guard=() must=() title
  words=$(printf '%s' "$1" | tr -cs 'A-Za-z' '\n' | grep -E '^[A-Za-z]{2,}$' | head -6 | paste -sd' ' -) || true
  title=${5:-"Unblock stuck ${words:-work}?"}
  why=${6:-"$1 is stuck on: $4. Its owner and Main were told and have not cleared it."}
  [ "${#why}" -le 200 ] || why="${why:0:197}..."
  # The board gate takes only a must ask (bin/jg-ask-gate-lib.sh). A worker stuck
  # on a prompt is waiting on a credential or login, which is one; every other
  # wait is Main's to settle, so the gate records it there and the board stays
  # the captain's alone.
  case "$3" in prompt*) guard=(--guard security); must=(--must credential-login) ;; esac
  (cd "$JG_HOME" && SIGN_OFF_FILER=juggernaut-watch "$_JG_WAIT_TIMER_DIR/jg-question-card.sh" post \
    --route main \
    --ask-ref "waiting-$1" --key "$2" --title "$title" --why "$why" \
    --detail "Task $1, wait $3. Card $2. It closes by itself when the wait ends." \
    --outcome yes="Main clears or answers the wait now." --outcome no="It stays stuck until you steer it." \
    --recommend yes --recommend-reason "Its owner and Main were alerted and the wait is still open." \
    --default no ${guard[@]+"${guard[@]}"} ${must[@]+"${must[@]}"} --priority P1) >/dev/null 2>&1 \
    || { echo "waiting timers: board card for $1 was not posted (sign-off-axi refused or is missing)" >&2; return 1; }
}

jg_wait_timer_card_dismiss() {  # <card-key>
  command -v sign-off-axi >/dev/null 2>&1 || return 0
  (cd "$JG_HOME" && sign-off-axi dismiss "$1") >/dev/null 2>&1 || true
}

# An episode's first fire: the ladder's first step in it, else its owner wake;
# nothing when no rung fired.
jg_wait_timer_first_fire() {  # <record> <task>
  local since owner first
  IFS=$'\t' read -r _ since owner _ < "$1" 2>/dev/null || return 0
  first=$(jg_wait_action_spent "$2" "${since:-0}" first)
  case "$owner" in ''|*[!0-9]*|0|1) owner='' ;; esac
  printf '%s' "${first:-$owner}"
}

# Minutes from <first fire> to <now>, one decimal; nothing without a first fire.
jg_wait_timer_fired_minutes() {  # <first fire> <now>
  [ -n "$1" ] || return 0
  awk -v s=$(($2 - $1)) 'BEGIN { printf "%.1f", s / 60 }'
}

# The metrics ledger's row for an escalation that cleared, one per episode whose
# first rung fired: data/metrics/escalations.tsv, columns cleared, task, key,
# first_fire, minutes, level (the highest rung reached: owner, main or card),
# acts (the ladder's own steps, or -), why.
jg_wait_timer_ledger() {  # <record> <task> <now> <first fire> <minutes> <why>
  local file=${JG_DATA_OVERRIDE:-$JG_HOME/data}/metrics/escalations.tsv since parent key card level acts
  [ -n "$5" ] || return 0
  IFS=$'\t' read -r _ since _ parent key _ card _ < "$1" || return 0
  level=owner
  [ "${parent:-0}" = 0 ] || level=main
  [ "${card:-0}" = 0 ] || level=card
  acts=$(jg_wait_action_spent "$2" "$since")
  mkdir -p "${file%/*}" || return 0
  [ -s "$file" ] || printf 'cleared\ttask\tkey\tfirst_fire\tminutes\tlevel\tacts\twhy\n' > "$file"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$3" "$2" "$key" "$4" "$5" "$level" "${acts:--}" "$6" >> "$file" || true
}

# End an episode: resolve its parent report (a lead home) or dismiss its card
# (the main home), record its minutes in the metrics ledger, then drop it.
# Returns 1 when the parent report failed, so the episode is kept and retried
# next poll.
jg_wait_timer_end() {  # <record> <task> <parent> <key> <card> <why>
  local now first mins
  now=$(date +%s) || return 1
  first=$(jg_wait_timer_first_fire "$1" "$2")
  mins=$(jg_wait_timer_fired_minutes "$first" "$now")
  if [ "$3" != 0 ] && [ -e "$JG_HOME/.jg-squad-lead-home" ]; then
    jg_wait_timer_report "resolved [key=$4]: waiting-timer-cleared: $2 $6${mins:+ after $mins min}" || return 1
  fi
  [ "$5" = 0 ] || jg_wait_timer_card_dismiss "$4-card"
  jg_wait_timer_ledger "$1" "$2" "$now" "$first" "$mins" "$6"
  rm -f "$1" "$STATE/.waiting-timers/.raised/$2"
}

# Main's side of a lead's overdue report: a waiting-timer-overdue line the lead
# appended to this home's state/<lead>.status (its parent channel), never the
# lead's own child records. On first sight and every <interval> the lead is
# nudged (a busy lead reads the steer when its turn ends) naming the blocked worker and
# its wait; at <card-secs> since the worker's wait began the board card is
# posted, and kept, until the lead resolves the report. One record per open
# report under state/.waiting-relay/: first-seen, nudged, card times.
jg_wait_timers_relay() {  # <now> <interval> <card-secs>
  local now=$1 interval=$2 card_secs=$3 rdir="$STATE/.waiting-relay" meta lead window rows k verb text
  local r seen='|' first nudged card worker since wverb wsrc ask
  mkdir -p "$rdir" || return 1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(jg_meta_get "$meta" kind)" = squad_lead ] || continue
    lead=${meta##*/}; lead=${lead%.meta}
    window=$(jg_backend_target_of_meta "$meta")
    rows=$(status_open_decisions "$STATE/$lead.status")
    while IFS=$'\t' read -r k verb text; do
      case "$k" in waiting-timer-*) ;; *) continue ;; esac
      case "$k" in *[!A-Za-z0-9._-]*) continue ;; esac
      case "$text" in waiting-timer-overdue:*|waiting-timer-backlog-overdue:*) ;; *) continue ;; esac
      seen="$seen$k|"
      r="$rdir/$k"
      first=$now nudged=0 card=0
      if [ -f "$r" ] && [ ! -L "$r" ]; then IFS=$'\t' read -r first nudged card < "$r" || true; fi
      # A stalled ready backlog is the lead's own dispatch: Main steers the
      # lead on every interval, and the card follows <card-secs> after Main
      # first saw the report, so what neither the lead nor Main starts reaches
      # the captain.
      case "$text" in
        waiting-timer-backlog-overdue:*)
          wsrc=${text#*\(}; wsrc=${wsrc%%); Main must*}
          if [ "${nudged:-0}" -eq 0 ] || [ $((now - nudged)) -ge "$interval" ]; then
            if declare -F lead_nudge >/dev/null; then
              lead_nudge "$lead" "$window" "waiting-relay-$k-$now" "You have ready backlog work that can start now, and nothing has started ($wsrc). Dispatch it now, P0 first, up to project capacity, or hold each item with the reason it waits." \
                || echo "waiting timers: nudge to squad lead $lead about its ready backlog was not recorded" >&2
            fi
            nudged=$now
          fi
          if { [ "${card:-0}" -eq 0 ] && [ $((now - first)) -ge "$card_secs" ]; } \
            || { [ "${card:-0}" -gt 0 ] && [ $((now - card)) -ge "$interval" ]; }; then
            worker=$(printf '%s' "$lead" | tr -cs 'A-Za-z' '\n' | grep -E '^[A-Za-z]{2,}$' | head -6 | paste -sd' ' -) || true
            jg_wait_timer_card "$lead" "$k-card" ready-backlog "$wsrc" "Start the stalled ${worker:-lead} backlog?" \
              "Lead $lead has ready work that can start ($wsrc) and has started nothing. It and Main were told." || true
            card=$now
          fi
          printf '%s\t%s\t%s\n' "$first" "$nudged" "${card:-0}" > "$r.tmp.$$" && mv "$r.tmp.$$" "$r" || return 1
          continue
          ;;
      esac
      worker=${text#waiting-timer-overdue: }; worker=${worker%% *}
      wverb=${text#*\(}; wverb=${wverb%%,*}
      since=$(printf '%s' "$text" | sed -n 's/.*since=\([0-9]\{1,12\}\)).*/\1/p')
      wsrc=${text##*source=\[}; wsrc=${wsrc%]}
      [ -n "$since" ] || since=${first:-$now}
      if [ "${nudged:-0}" -eq 0 ] || [ $((now - nudged)) -ge "$interval" ]; then
        if declare -F lead_nudge >/dev/null; then
          ask="Clear it now: answer it, steer it, or report blocked: with what it needs."
          lead_nudge "$lead" "$window" "waiting-relay-$k-$now" "Your worker $worker has been stuck $((now - since))s on: $wsrc. $ask Main posts it to the captain's board at $((card_secs / 60)) minutes." \
            || echo "waiting timers: nudge to squad lead $lead about $worker was not recorded" >&2
        fi
        nudged=$now
      fi
      if { [ "${card:-0}" -eq 0 ] && [ $((now - since)) -ge "$card_secs" ]; } \
        || { [ "${card:-0}" -gt 0 ] && [ $((now - card)) -ge "$interval" ]; }; then
        jg_wait_timer_card "$worker" "$k-card" "$wverb" "$wsrc" || true
        card=$now
      fi
      printf '%s\t%s\t%s\n' "$first" "$nudged" "${card:-0}" > "$r.tmp.$$" && mv "$r.tmp.$$" "$r" || return 1
    done <<EOF
$rows
EOF
  done
  for r in "$rdir"/*; do
    [ -f "$r" ] && [ ! -L "$r" ] || continue
    k=${r##*/}
    case "$seen" in *"|$k|"*) continue ;; esac
    IFS=$'\t' read -r first nudged card < "$r" || true
    [ "${card:-0}" = 0 ] || jg_wait_timer_card_dismiss "$k-card"
    rm -f "$r" || return 1
  done
}

# A lead home's stalled ready backlog (README "Stalled ready backlog"): ready
# work that could start, a free lane, and nothing
# started for JG_READY_STALL_SECS. The watcher's ready_backlog_stall_state owns
# the condition; this owns the rungs.
# One episode at state/.waiting-timers/.ready-backlog: since, open lane ids
# (- for none), key, first report time (0 before it), last fire time. A new lane id is a
# start, so it ends the episode and re-arms the clock; the condition clearing
# ends it. Each fire wakes this lead and reports to Main, again every
# <interval>; Main's relay steers the lead and posts the card (jg_wait_timers_relay).
# While ready work waits but the condition does not hold, state/.waiting-timers/
# .ready-backlog-why records why (since, reason, open/target), so a quiet
# backlog is explainable from disk.
# A home with a pause record (bin/jg-pause-lib.sh) dispatches nothing by design,
# so it arms and escalates nothing: an episode reported before the pause is
# closed and the record dropped, and the clock starts again when the pause lifts.
jg_wait_timers_backlog() {  # <now> <interval>
  local now=$1 interval=$2 stall=${JG_READY_STALL_SECS:-$(jg_wait_timers_table ready-stall)} every=${JG_READY_STALL_POLL_SECS:-60}
  local record="$STATE/.waiting-timers/.ready-backlog" mark="$STATE/.waiting-timers/.ready-backlog-checked"
  local whyfile="$STATE/.waiting-timers/.ready-backlog-why" why_old
  local rc since='' lanes='' key='' reported=0 last=0 id lead age report reason cond
  case "$stall" in ''|*[!0-9]*|0*) echo "waiting timers: JG_READY_STALL_SECS must be positive decimal seconds" >&2; return 1 ;; esac
  case "$every" in ''|*[!0-9]*) echo "waiting timers: JG_READY_STALL_POLL_SECS must be decimal seconds" >&2; return 1 ;; esac
  declare -F ready_backlog_stall_state >/dev/null || return 0
  [ ! -e "$mark" ] || [ "$(age_of "$mark")" -ge "$every" ] || return 0
  touch "$mark" || return 1
  lead=$(jg_parent_channel_home_id "$JG_HOME") || return 0
  # A home the captain paused is silent: the same rule the ready-work check
  # already honours for a declared pause, read from its one owner. A report left
  # open by the pause is resolved, and the record goes, so the backlog rings
  # again from a fresh clock once the pause lifts.
  if declare -F fleet_paused >/dev/null && fleet_paused; then
    if [ -f "$record" ] && [ ! -L "$record" ]; then
      IFS=$'\t' read -r since lanes key reported last < "$record" || since=
      case "${reported:-0}" in ''|*[!0-9]*) reported=0 ;; esac
      if [ "$reported" -gt 0 ]; then
        jg_wait_timer_report "resolved [key=$key]: waiting-timer-cleared: $lead ready backlog: the home is paused" || return 0
      fi
    fi
    rm -f "$record" "$whyfile" || return 1
    return 0
  fi
  if [ -f "$record" ] && [ ! -L "$record" ]; then
    IFS=$'\t' read -r since lanes key reported last < "$record" || since=
    case "$since:${reported:-0}:${last:-0}" in *[!0-9:]*|:*) since= ;; esac
    case "$key" in waiting-timer-*[!A-Za-z0-9._-]*|'') since= ;; waiting-timer-*) ;; *) since= ;; esac
  fi
  rc=0; ready_backlog_stall_state || rc=$?
  [ "$rc" -ne 2 ] || return 0
  if [ "$rc" -eq 1 ] && [ -n "${READY_STALL_WHY:-}" ]; then
    why_old=
    [ ! -f "$whyfile" ] || IFS=$'\t' read -r _ why_old _ < "$whyfile" || why_old=
    [ "$why_old" = "$READY_STALL_WHY" ] || printf '%s\t%s\t%s/%s\n' "$now" "$READY_STALL_WHY" "$READY_STALL_OPEN" "$READY_STALL_TARGET" > "$whyfile" || return 1
  else
    rm -f "$whyfile" || return 1
  fi
  if [ -n "$since" ] && [ "$rc" -eq 0 ]; then
    for id in ${READY_STALL_LANES//,/ }; do
      case ",$lanes," in *",$id,"*) ;; *) rc=3; break ;; esac
    done
  fi
  if [ -n "$since" ] && [ "$rc" -ne 0 ]; then
    if [ "${reported:-0}" -gt 0 ]; then
      reason="the lead started work"
      [ "$rc" -eq 3 ] || reason="no ready work waits to start now"
      jg_wait_timer_report "resolved [key=$key]: waiting-timer-cleared: $lead ready backlog: $reason" || return 0
    fi
    rm -f "$record" || return 1
    since=
  fi
  [ "$rc" -ne 1 ] || return 0
  if [ -z "$since" ]; then
    since=$now reported=0 last=0
    key=$(jg_wait_timer_key "$lead" "$now" ready-backlog) || return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$since" "${READY_STALL_LANES:--}" "$key" "$reported" "$last" > "$record.tmp.$$" \
    && mv "$record.tmp.$$" "$record" || return 1
  age=$((now - since))
  [ "$age" -ge "$stall" ] || return 0
  [ "$reported" -eq 0 ] || [ $((now - last)) -ge "$interval" ] || return 0
  cond="free lanes"
  [ "$READY_STALL_MODE" != no-worker ] || cond="no worker working"
  report="blocked [key=$key]: waiting-timer-backlog-overdue: $lead (ready work $READY_STALL_IDS, $cond $READY_STALL_OPEN/$READY_STALL_TARGET open, nothing started for ${age}s, since=$since); Main must steer the lead to dispatch it"
  jg_wait_timer_report "$report" || return 0
  [ "$reported" -gt 0 ] || reported=$now
  last=$now
  printf '%s\t%s\t%s\t%s\t%s\n' "$since" "${READY_STALL_LANES:--}" "$key" "$reported" "$last" > "$record.tmp.$$" \
    && mv "$record.tmp.$$" "$record" || return 1
  reason="check: ready backlog stalled: $READY_STALL_IDS waits with $cond ($READY_STALL_OPEN/$READY_STALL_TARGET open) and nothing started for ${age}s - dispatch them now, P0 first, up to project capacity, or hold each with why it waits; Main was told id=$key"
  if ! jg_wake_queued_keys check | grep -Fx "$key-stall" >/dev/null; then
    jg_wake_append check "$key-stall" "$reason" || return 1
  fi
  wake "$reason"
}

# A recorded ready PR that is green at its head and unmerged under yolo is one
# slow delivery (README "Green PR left unmerged"): once it has stayed so for
# JG_GREEN_PR_SECS, the slow-delivery alert (bin/jg-alert.sh) is raised for the
# task, once per episode. The alert resolves on a merge (the poll retires
# or the forge answers not open), a new head (the clock re-arms), a pause or
# captain hold on the task, or yolo off. Only GitHub is read; any other forge,
# an unreadable answer, or a missing gh stays quiet. State: .green-pr/<task>
# holds checked, since, head, url; a forge read runs at most every
# JG_GREEN_PR_POLL_SECS, and an answer older than three reads lapses.
# jg_wait_timer_green_pr_resolve <task>: the PR is no longer green and unmerged for this task; resolve its alert when one is live.
jg_wait_timer_green_pr_resolve() {
  local alert="$_JG_WAIT_TIMER_DIR/jg-alert.sh" key="slow-delivery--$1"
  JG_STATE_OVERRIDE="$STATE" "$alert" word "$key" >/dev/null 2>&1 && JG_STATE_OVERRIDE="$STATE" "$alert" resolve "$key" >/dev/null 2>&1
  return 0
}
jg_wait_timer_green_pr_read() {  # <pr-url> -> head on stdout; 0 green, 1 not green, 2 unreadable
  local row prstate draft merge head
  declare -F jg_pr_url_parse >/dev/null && jg_pr_url_parse "$1" && [ "$JG_PR_PROVIDER" = github ] || return 1
  command -v gh >/dev/null 2>&1 || return 2
  row=$(jg_run_timed 20 gh pr view "$JG_PR_NUMBER" --repo "$JG_PR_PATH" --json state,isDraft,mergeStateStatus,headRefOid \
    --jq '[.state, (.isDraft | tostring), .mergeStateStatus, .headRefOid] | @tsv' 2>/dev/null) || return 2
  IFS=$'\t' read -r prstate draft merge head <<<"$row"
  case "$head" in ''|*[!0-9a-f]*) return 2 ;; esac
  [ "$prstate" = OPEN ] && [ "$draft" = false ] && [ "$merge" = CLEAN ] || return 1
  printf '%s\n' "$head"
}

jg_wait_timers_green_pr() {  # <now>
  local now=$1 dir="$STATE/.green-pr" every=${JG_GREEN_PR_POLL_SECS:-120} stall=${JG_GREEN_PR_SECS:-900}
  local meta id kind url rec checked since head live rc declared until
  case "$stall" in ''|*[!0-9]*|0*) echo "waiting timers: JG_GREEN_PR_SECS must be positive decimal seconds" >&2; return 1 ;; esac
  case "$every" in ''|*[!0-9]*) echo "waiting timers: JG_GREEN_PR_POLL_SECS must be decimal seconds" >&2; return 1 ;; esac
  mkdir -p "$dir" || return 1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    rec="$dir/$id"
    url=$(jg_meta_get "$meta" pr); kind=$(jg_meta_get "$meta" kind)
    case "${kind:-ship}" in ship) ;; *) url= ;; esac
    [ "$(jg_meta_get "$meta" yolo)" = on ] && [ -f "$STATE/$id.check.sh" ] || url=
    if [ -n "$url" ]; then
      declared=$(status_declared_wait_line "$STATE/$id.status")
      if status_is_captain_held "$declared" \
        || { status_is_paused "$declared" && { until=$(status_paused_until "$declared") || until=$((now + 1)); [ "$now" -lt "$until" ]; }; } \
        || { declare -F task_captain_call_open >/dev/null && task_captain_call_open "$id"; }; then url=; fi
    fi
    if [ -z "$url" ]; then rm -f "$rec"; jg_wait_timer_green_pr_resolve "$id"; continue; fi
    checked=0 since=$now head=
    if [ -f "$rec" ] && [ ! -L "$rec" ]; then
      IFS=$'\t' read -r checked since head live < "$rec" || checked=0
      case "$checked:$since" in *[!0-9:]*|:*) checked=0 since=$now head= ;; esac
      [ "$live" = "$url" ] || { checked=0 since=$now head=; }
    fi
    if [ "$checked" -eq 0 ] || [ $((now - checked)) -ge "$every" ]; then
      rc=0; live=$(jg_wait_timer_green_pr_read "$url") || rc=$?
      case "$rc" in
        0) [ "$live" = "$head" ] || since=$now
           printf '%s\t%s\t%s\t%s\n' "$now" "$since" "$live" "$url" > "$rec.tmp.$$" && mv "$rec.tmp.$$" "$rec" || return 1
           checked=$now head=$live ;;
        1) rm -f "$rec"; jg_wait_timer_green_pr_resolve "$id"; continue ;;
        *) [ "$checked" -gt 0 ] || continue ;;
      esac
    fi
    # An answer that was never refreshed (the forge stopped answering) lapses.
    if [ $((now - checked)) -le $((every * 3)) ] && [ $((now - since)) -ge "$stall" ]; then
      JG_STATE_OVERRIDE="$STATE" "$_JG_WAIT_TIMER_DIR/jg-alert.sh" raise slow-delivery "$id" --kind ship-delivering --ticket "$id" --deliver >/dev/null 2>&1 \
        || echo "waiting timers: could not raise the slow-delivery alert for $id ($url is green at ${head:0:8} and unmerged)" >&2
    else
      jg_wait_timer_green_pr_resolve "$id"
    fi
  done
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    [ -f "$STATE/${rec##*/}.meta" ] || { rm -f "$rec"; jg_wait_timer_green_pr_resolve "${rec##*/}"; }
  done
  return 0
}

jg_wait_timers_definition_timers() {
  "$_JG_WAIT_TIMER_DIR/jg-escalation-workflows.sh" timers 2>/dev/null
}

# The ladder's rung timers belong to the alert table (bin/jg-alert.sh timers); an environment override still wins.
jg_wait_timers_table() {  # <name>
  "$_JG_WAIT_TIMER_DIR/jg-alert.sh" timers 2>/dev/null | awk -F '\t' -v n="$1" '$1 == n { print $2 }'
}

jg_wait_timers_tick() {
  local escalate=${JG_WAIT_ESCALATE_SECS:-$(jg_wait_timers_table escalate)} card_secs=${JG_WAIT_CARD_SECS:-$(jg_wait_timers_table card)}
  local interval=${JG_PROMPT_REALERT_SECS:-$(jg_wait_timers_table realert)}
  # The owner alert and the pause cadence are the escalation workflow
  # definition's timers, and the owner rung itself is delivered there
  # (bin/jg-escalation-workflows.sh, live on every poll). The two numbers are
  # read from it because the rungs this library still owns measure their offsets
  # from the owner alert: the escalation runs <escalate> seconds from the
  # episode's start and a declared pause rechecks at the pause cadence. Neither
  # number is written down again here.
  local alert paused_alert silence numbers
  numbers=$(jg_wait_timers_definition_timers) || {
    echo "waiting timers: the escalation workflow definition is unreadable" >&2
    return 1
  }
  alert=$(printf '%s\n' "$numbers" | awk -F '\t' '$1 == "owner" { print $2 }')
  paused_alert=$(printf '%s\n' "$numbers" | awk -F '\t' '$1 == "pause" { print $2 }')
  # The silent source lapses on the definition's silence timer, not the poll bound.
  silence=$(printf '%s\n' "$numbers" | awk -F '\t' '$1 == "silence" { print $2 }')
  local meta task backend window session native sessions='|' blocked='|' unknown='|' rows actor=Main lead=''
  local dir="$STATE/.waiting-timers" now record declaration verb signature old since owner parent key misses age reason until bound lapse rc
  local wait_state pause_key dkey src source card last wsrc fresh session_id fired every level pending='' hop hopstart ceiling fp forced deadline acts
  for native in "$alert" "$paused_alert" "$escalate" "$card_secs" "$interval"; do
    case "$native" in ''|*[!0-9]*|0* ) echo "waiting timers: thresholds must be positive decimal seconds" >&2; return 1 ;; esac
    [ "${#native}" -le 9 ] || { echo "waiting timers: threshold exceeds nine digits" >&2; return 1; }
  done
  [ "$escalate" -gt "$alert" ] || { echo "waiting timers: escalation must be later than owner alert" >&2; return 1; }
  [ "$card_secs" -gt "$escalate" ] || { echo "waiting timers: the board card must be later than escalation" >&2; return 1; }
  now=$(date +%s) || return 1
  # POLL may be fractional (sleep accepts 0.2); whole seconds are enough here.
  fresh=${POLL:-15}; fresh=${fresh%%.*}
  fresh=$(( ${fresh:-0} * 3 + 30 ))
  if [ -e "$JG_HOME/.jg-squad-lead-home" ]; then actor='owning lead'; lead=1; fi
  mkdir -p "$dir" || return 1
  # A new supervisor session (a restart or a lead's relaunch) re-presents every
  # wait already past its owner alert on its first ticks, so nothing it was told
  # before is lost with the old session.
  session_id=$(cat "$STATE/.lock" "$STATE/.lock-session" 2>/dev/null | hash_pane) || return 1
  if [ -f "$dir/.presented" ] && [ "$(cat "$dir/.presented")" != "$session_id" ]; then
    for record in "$dir"/*; do
      [ -f "$record" ] && [ ! -L "$record" ] || continue
      IFS=$'\t' read -r old since owner parent key misses card last < "$record" || continue
      case "$owner" in ''|*[!0-9]*) continue ;; esac
      [ "$owner" -gt 1 ] || continue
      jg_wait_timer_save "$record" "$old" "$since" "$owner" "${parent:-0}" "$key" "${misses:-0}" "${card:-0}" 1 || return 1
    done
  fi
  [ "$(cat "$dir/.presented" 2>/dev/null)" = "$session_id" ] || printf '%s\n' "$session_id" > "$dir/.presented" || return 1
  # One bounded native read per recorded session, not one per lane. A session whose
  # read fails is unknown for this poll: its lanes keep their episodes untouched
  # while every other lane is still monitored.
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    backend=$(jg_meta_get "$meta" backend)
    [ "$backend" = herdr ] || continue
    window=$(jg_meta_get "$meta" window)
    [ -n "$window" ] || continue
    jg_backend_source herdr || return 1
    jg_backend_herdr_parse_target "$window" || continue
    session=$JG_BACKEND_HERDR_SESSION
    case "$sessions" in *"|$session|"*) continue ;; esac
    sessions="$sessions$session|"
    bound=$JG_BACKEND_HERDR_READ_TIMEOUT
    case "$bound" in ''|0*|*[!0-9]*) echo "waiting timers: native read timeout must be positive decimal seconds" >&2; return 1 ;; esac
    [ "${#bound}" -le 9 ] || return 1
    # shellcheck disable=SC2016 # The child shell expands its positional parameters.
    if native=$(jg_run_timed "$bound" bash -c '
      . "$1"
      jg_backend_source herdr || exit 1
      JG_BACKEND_HERDR_TIMEOUT= jg_backend_herdr_cli "$2" agent list
    ' jg-wait-native "$_JG_WAIT_TIMER_DIR/jg-backend.sh" "$session"); then
      :
    else
      rc=$?
      echo "waiting timers: agent list for $session failed (code $rc, deadline ${bound}s); its lanes are unknown this poll" >&2
      unknown="$unknown$session|"
      continue
    fi
    rows=$(printf '%s' "$native" | jq -er '
      if (.result.agents | type) != "array" then error("agent.list missing agents array")
      else [.result.agents[] | select(.agent_status == "blocked") |
        if (.pane_id | type) == "string" then .pane_id else error("blocked agent missing pane_id") end] | join("\n") end') || {
      echo "waiting timers: agent list for $session is malformed; its lanes are unknown this poll" >&2
      unknown="$unknown$session|"
      continue
    }
    while IFS= read -r window; do
      [ -z "$window" ] || blocked="$blocked$session:$window|"
    done <<EOF
$rows
EOF
  done
  # Removed tasks also end their parent report and card, even when cleanup
  # removed the status log and metadata before the next poll.
  for record in "$dir"/*; do
    [ -f "$record" ] || continue
    task=${record##*/}
    [ ! -L "$record" ] || { echo "waiting timers: symlink episode $record" >&2; return 1; }
    [ ! -f "$STATE/$task.meta" ] || continue
    IFS=$'\t' read -r old since owner parent key misses card last < "$record" || return 1
    jg_wait_timer_end "$record" "$task" "${parent:-0}" "$key" "${card:-0}" removed || continue
  done
  for src in "$STATE"/.wait-sources/*; do
    [ -f "$src" ] || continue
    task=${src##*/}; task=${task%.*}
    [ -f "$STATE/$task.meta" ] || rm -f "$src" || return 1
  done
  jg_wait_actions_prune
  jg_wait_timers_green_pr "$now" || return 1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=${meta##*/}; task=${task%.meta}
    _jg_parent_channel_id_valid "$task" || { echo "waiting timers: invalid task id in $meta" >&2; return 1; }
    window=$(jg_backend_target_of_meta "$meta")
    if [ "$(jg_backend_of_meta "$meta")" = herdr ]; then
      case "$unknown" in *"|${window%%:*}|"*) continue ;; esac
    fi
    declaration=''; dkey=''; wsrc=''
    if [ "$(jg_meta_get "$meta" harness)" != cursor ]; then
      case "$blocked" in
        *"|$window|"*) [ -z "$window" ] || declaration=herdr-blocked ;;
      esac
    fi
    # Wait sources the watcher records: an unanswered permission prompt (kept
    # only while the prompt gate still sees it, so a dead pane's prompt lapses)
    # and a Squad Lead whose own supervision is not running.
    for src in prompt question account quota errors silent supervision; do
      [ -z "$declaration" ] || break
      record="$STATE/.wait-sources/$task.$src"
      [ -f "$record" ] && [ ! -L "$record" ] || continue
      # A silent record is rewritten on every scan of its pane and cleared by the first
      # scan that sees progress, so a late scan (a loaded host) has not ended the silence:
      # it lapses only after a whole silence window unread, never after a few polls.
      lapse=$fresh; [ "$src" != silent ] || lapse=${silence:-$fresh}
      [ "$src" = supervision ] || [ "$(age_of "$record")" -lt "$lapse" ] || continue
      declaration=$(head -n 1 "$record" | tr '\t' ' ' | cut -c1-300)
      [ -z "$declaration" ] || wsrc=$src
    done
    if [ -z "$declaration" ]; then
      rows=$(status_own_open_decisions "$STATE/$task.status")
      while IFS=$'\t' read -r old verb native; do
        case "$verb" in blocked|needs-decision) declaration="$verb [key=$old]: $native"; dkey=$old ;; esac
      done <<EOF
$rows
EOF
      [ -n "$declaration" ] || declaration=$(status_declared_wait_line "$STATE/$task.status")
      status_is_paused "$declaration" || case "$declaration" in blocked*|needs-decision*) ;; *) declaration='' ;; esac
    fi
    wait_state=''
    if status_is_paused "$declaration"; then
      wait_state=$(jg_wait_machine_state "$_JG_WAIT_TIMER_DIR" "$task") || return 1
    fi
    if [ "$wait_state" != paused-no-date ] && status_is_paused "$declaration" && until=$(status_paused_until "$declaration") && [ "$now" -lt "$until" ]; then
      declaration=''
    fi
    # A captain hold waits on the captain, so a held lane never arms an episode.
    # Checked before the record is read: a check made only once an episode is due
    # would clear it and let the still-declared wait re-arm it on the next poll.
    if [ -n "$declaration" ] && task_captain_call_open "$task"; then
      declaration=''
    fi
    # A parked or finished lane has an owner already (jg_wait_timer_quiet).
    if [ -n "$declaration" ] && [ "$declaration" != herdr-blocked ] && jg_wait_timer_quiet "$task" "$wait_state" "$wsrc"; then
      declaration=''
    fi
    record="$dir/$task"
    src=${dkey:-$wsrc}
    if [ -z "$src" ] && status_is_paused "$declaration"; then src=$(_jg_decision_key "$declaration") || src=default; fi
    [ "$declaration" != herdr-blocked ] || src=herdr-blocked
    old=''; since=$now; owner=0; parent=0; misses=0; card=0; last=0; key=$(jg_wait_timer_key "$task" "$now" "$src") || return 1
    if [ -e "$record" ] || [ -L "$record" ]; then
      [ -f "$record" ] && [ ! -L "$record" ] || { echo "waiting timers: invalid episode $record" >&2; return 1; }
      IFS=$'\t' read -r old since owner parent key misses card last < "$record" || return 1
      case "$since:$owner:$parent:$key:$card:$last" in
        *[!0-9A-Za-z._:-]*) echo "waiting timers: corrupt episode $record" >&2; return 1 ;;
      esac
      case "$since" in ''|*[!0-9]*) echo "waiting timers: invalid episode time $record" >&2; return 1 ;; esac
      [ "${#since}" -le 12 ] && [ -n "$key" ] || { echo "waiting timers: corrupt episode identity $record" >&2; return 1; }
      case "$owner" in ''|*[!0-9]*) echo "waiting timers: invalid owner time $record" >&2; return 1 ;; esac
      [ "${#owner}" -le 12 ] || return 1
      card=${card:-0}; last=${last:-0}
      # parent: 0 none, 1 an escalation from before its time was kept, else its time.
      for native in "$parent" "$card" "$last"; do
        case "$native" in ''|*[!0-9]*) echo "waiting timers: invalid episode levels $record" >&2; return 1 ;; esac
        [ "${#native}" -le 12 ] || { echo "waiting timers: invalid episode levels $record" >&2; return 1; }
      done
      misses=${misses:-0}
      case "$misses" in 0|1) ;; *) echo "waiting timers: invalid episode misses $record" >&2; return 1 ;; esac
      if [ "$owner" -eq 1 ]; then owner=0; fi
    fi
    if status_is_paused "$declaration"; then
      # A paused episode keys on window, verb and phase key, not the full
      # declaration line: a worker refreshing its pause prose (or the [at=]
      # stamp moving) is the same wait, so its original observation time and
      # its owner rechecks survive the rewrite. A different phase key is a
      # different wait and re-arms.
      pause_key=$(_jg_decision_key "$declaration") || pause_key=default
      signature=$(printf '%s' "$window|$(status_line_verb "$declaration")|$pause_key" | hash_pane)
    elif [ "$wsrc" = silent ]; then
      # The silent source restates its age on every scan ("... for 1205s"); the
      # wait is the silence, not the count, so it keeps its clock as the count grows.
      signature=$(printf '%s' "$window|silent" | hash_pane)
    else
      signature=$(printf '%s' "$window|$declaration" | hash_pane)
    fi
    if [ -z "$declaration" ] && [ -n "$old" ] && [ "$misses" -eq 0 ]; then
      jg_wait_timer_save "$record" "$old" "$since" "$owner" "$parent" "$key" 1 "$card" "$last" || return 1
      continue
    fi
    if [ -z "$declaration" ] || [ "$old" != "$signature" ]; then
      if [ -n "$old" ]; then
        jg_wait_timer_end "$record" "$task" "$parent" "$key" "$card" "changed state" || continue
      fi
      [ -n "$declaration" ] || continue
      since=$now; owner=0; parent=0; misses=0; card=0; last=0; key=$(jg_wait_timer_key "$task" "$now" "$src") || return 1
      jg_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" "$misses" || return 1
    elif [ "$misses" -ne 0 ]; then
      misses=0
      jg_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" "$misses" "$card" "$last" || return 1
    fi
    age=$((now - since))
    verb=$(status_line_verb "$declaration")
    [ -z "$wsrc" ] || verb=$wsrc
    [ "$declaration" != herdr-blocked ] || verb=herdr-blocked
    # An open decision names its key so the recipient clears the right one.
    [ -z "$dkey" ] || verb="$verb key=$dkey"
    # A declared pause is an expected wait, so its owner recheck rides the
    # JG_PAUSE_RESURFACE_SECS cadence (the same bound the stale path uses),
    # never the blocked/decision owner-alert threshold, and it never escalates.
    # Every report prints the exact unresolved source, not just the episode.
    source=$(printf '%s' "$declaration" | tr '\t\n' '  ' | cut -c1-160)
    # The owner rung and the pause cadence are not here: the escalation workflow
    # definition delivers them and stamps the episode's owner time. What follows
    # still owns the escalation, the board card and the re-alert cadence, and
    # rides the owner stamp the definition wrote.
    every=$interval
    if status_is_paused "$declaration"; then every=$paused_alert; fi
    [ "$wait_state" != paused-no-date ] || every=$JG_WAIT_PLACEHOLDER_SECS
    # A stuck state with a row in the owner table (jg-wait-actions-lib.sh) gets
    # its owner's steps from the ladder, each in the place of the rung due now.
    # A step stamps the owner time, so the next rung times from it; the row's
    # last step, "lead", clears that stamp, so the owner rung then wakes this
    # home's own owner and the Main rung follows as for any wait. A wait with
    # no row, or whose step failed, climbs as before.
    if ! status_is_paused "$declaration" && [ "$parent" -eq 0 ] \
      && { { [ "$owner" -le 1 ] && [ "$age" -ge "$alert" ]; } || { [ "$owner" -gt 1 ] && [ "$((now - owner))" -ge "$((escalate - alert))" ]; }; } \
      && jg_wait_action_next "$task" "$now" "$wsrc" "$(status_line_verb "$declaration")" "$dkey" "$declaration" \
      && jg_wait_action_take "$task" "$WAIT_ACT_NEXT_STATE" "$WAIT_ACT_NEXT" "$now" "$dkey" "$declaration" "$age"; then
      owner=$now
      [ "$WAIT_ACT_NEXT" != lead ] || owner=0
      jg_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" "$misses" "$card" "$last" || return 1
      continue
    fi
    [ "$owner" -gt 1 ] || continue
    acts=$(jg_wait_action_spent "$task" "$since")
    # What this wait says now, for the re-raise gate: the hop it sits on and its
    # fingerprint. The hop moves up the ladder as the rungs below are reached.
    deadline=''
    if status_is_paused "$declaration"; then deadline=$(status_paused_until "$declaration") || deadline=''; fi
    if ! status_is_paused "$declaration" && [ "$parent" -eq 0 ] \
      && [ "$((now - owner))" -ge "$((escalate - alert))" ] && [ "$age" -ge "$escalate" ]; then
      if [ -n "$lead" ]; then
        jg_wait_timer_report "blocked [key=$key]: waiting-timer-overdue: $task ($verb, observed ${age}s, since=$since); owning lead has not cleared the wait${acts:+; the ladder already took: $acts}; Main must unblock or steer the lead; source=[$source]" || continue
        parent=$now
        jg_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" "$misses" "$card" "$last" || return 1
        fp=$(jg_wait_timer_fingerprint main "$key" "$window" "$verb" "$actor" "$declaration" "$wsrc" "$deadline") || return 1
        jg_wait_timer_raised_save "$task" "$fp" "$now" 0 || true
      else
        # The reason line's leading word is the wake kind every consumer
        # classifies by, so it must read "check:" like the kind this row is
        # queued under: a prefix outside that taxonomy classifies as no wake at
        # all, and the escalation then reaches nobody.
        reason="check: waiting-state $task ($verb, observed ${age}s, level=main${acts:+; the ladder already took: $acts}; Main must unblock it now) id=$key source=[$source]"
        jg_wake_append check "$key-escalation" "$reason" || return 1
        parent=$now
        jg_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" "$misses" "$card" "$last" || return 1
        fp=$(jg_wait_timer_fingerprint main "$key" "$window" "$verb" "$actor" "$declaration" "$wsrc" "$deadline") || return 1
        jg_wait_timer_raised_save "$task" "$fp" "$now" 0 || true
        wake "$reason"
      fi
    fi
    # Only the main home posts a card: what Main cannot settle reaches the captain.
    # An account outage already raised its own card (renew the account or not).
    if [ -z "$lead" ] && ! status_is_paused "$declaration" && [ "$parent" -gt 0 ] && [ "$card" -eq 0 ] && [ "$age" -ge "$card_secs" ] \
      && ! jg_wait_action_raised_card "$task" "$since"; then
      jg_wait_timer_card "$task" "$key-card" "$verb" "$source" || true
      card=$now
      jg_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" "$misses" "$card" "$last" || return 1
    fi
    # Every rung reached fires again while the wait stays open.
    fired=$owner
    for native in "$parent" "$card" "$last"; do [ "$native" -le "$fired" ] || fired=$native; done
    [ "$last" -eq 1 ] || [ "$((now - fired))" -ge "$every" ] || continue
    forced=0; [ "$last" -ne 1 ] || forced=1
    # Reading or acknowledging a wake is not an unblock. An unresolved blocker
    # must ring at every due recheck until its source clears, even unchanged.
    status_is_paused "$declaration" || forced=1
    [ "$wait_state" != paused-no-date ] || forced=1
    last=$now
    jg_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" "$misses" "$card" "$last" || return 1
    # Expected pauses keep the change gate; unresolved waits always re-fire.
    if status_is_paused "$declaration"; then
      hop=pause hopstart=$owner ceiling=$paused_alert
    else
      hop=owner hopstart=$owner ceiling=$alert
      [ "$parent" -eq 0 ] || { hop=main hopstart=$parent; }
      [ "$card" -eq 0 ] || { hop=card hopstart=$card; }
      for native in "$escalate" "$card_secs" "$interval"; do [ "$native" -le "$ceiling" ] || ceiling=$native; done
    fi
    fp=$(jg_wait_timer_fingerprint "$hop" "$key" "$window" "$verb" "$actor" "$declaration" "$wsrc" "$deadline") || return 1
    if ! jg_wait_timer_raise_gate "$task" "$fp" "$hopstart" "$ceiling" "$now" "$forced"; then
      jg_wait_timer_unchanged_log "$now" "$task" "$key" "$hop" "$((now - hopstart))"
      # Keeping the one open board card is not a wake, so it stays on its cadence.
      if [ -z "$lead" ] && [ "$parent" -gt 0 ] && [ "$card" -ne 0 ]; then jg_wait_timer_card "$task" "$key-card" "$verb" "$source" || true; fi
      continue
    fi
    level=owner
    if [ "$parent" -gt 0 ] && [ -n "$lead" ]; then
      jg_wait_timer_report "blocked [key=$key]: waiting-timer-overdue: $task ($verb, observed ${age}s, since=$since); still not cleared; Main must unblock or steer the lead; source=[$source]" || true
    elif [ "$parent" -gt 0 ]; then
      level=main
      [ "$card" -eq 0 ] || jg_wait_timer_card "$task" "$key-card" "$verb" "$source" || true
    fi
    reason="check: waiting-state $task ($verb, observed ${age}s, level=$level; still open, $actor must recheck and unblock) id=$key source=[$source]"
    if ! jg_wake_queued_keys check | grep -Fx "$key-$level-again" >/dev/null; then
      jg_wake_append check "$key-$level-again" "$reason" || return 1
    fi
    [ -n "$pending" ] || pending=$reason
  done
  if [ -z "$lead" ]; then jg_wait_timers_relay "$now" "$interval" "$card_secs" || return 1; fi
  # Its own fire wakes once, after every lane's re-fire rows are queued.
  if [ -n "$lead" ]; then jg_wait_timers_backlog "$now" "$interval" || return 1; fi
  # Re-fires queue their rows first and wake once, so every open wait is
  # re-presented in one cycle.
  [ -z "$pending" ] || wake "$pending"
  return 0
}
