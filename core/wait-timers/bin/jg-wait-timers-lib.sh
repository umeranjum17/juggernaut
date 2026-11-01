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
  local words why guard=() must=() title pr
  words=$(printf '%s' "$1" | tr -cs 'A-Za-z' '\n' | grep -E '^[A-Za-z]{2,}$' | head -6 | paste -sd' ' -) || true
  title=${5:-"Unblock stuck ${words:-work}?"}
  why=${6:-"$1 is stuck on: $4. Its owner and Main were told and have not cleared it."}
  case "$3" in
    greenpr)
      pr=${4#greenpr: }; pr=${pr%% *}
      title=${5:-"Merge the green ${words:-work} PR?"}
      why=${6:-"$pr is green and unmerged under yolo. Its owner and Main were told and have not merged it."} ;;
  esac
  [ "${#why}" -le 200 ] || why="${why:0:197}..."
  # The board gate takes only a must ask (bin/jg-ask-gate-lib.sh). A worker stuck
  # on a prompt is waiting on a credential or login, which is one; every other
  # wait is Main's to settle, so the gate records it there and the board stays
  # the captain's alone.
  case "$3" in prompt*) guard=(--guard security); must=(--must credential-login) ;; esac
  (cd "$JG_HOME" && SIGN_OFF_FILER=juggernaut-watch "$_JG_WAIT_TIMER_DIR/jg-question-card.sh" post \
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

# End an episode: resolve its parent report (a lead home) or dismiss its card
# (the main home), then drop it. Returns 1 when the parent report failed, so the
# episode is kept and retried next poll.
jg_wait_timer_end() {  # <record> <task> <parent> <key> <card> <why>
  if [ "$3" != 0 ] && [ -e "$JG_HOME/.jg-squad-lead-home" ]; then
    jg_wait_timer_report "resolved [key=$4]: waiting-timer-cleared: $2 $6" || return 1
  fi
  [ "$5" = 0 ] || jg_wait_timer_card_dismiss "$4-card"
  rm -f "$1"
}

# Main's side of a lead's overdue report: a waiting-timer-overdue line the lead
# appended to this home's state/<lead>.status (its parent channel), never the
# lead's own child records. On first sight and every <interval> the lead is
# nudged (interrupted first when busy mid-turn) naming the blocked worker and
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
          [ "$wverb" != greenpr ] || ask="Merge it now with bin/jg-pr-merge.sh, or record a hold with the reason it waits."
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
# work that could start, a free lane or no worker provably working, and nothing
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
jg_wait_timers_backlog() {  # <now> <interval>
  local now=$1 interval=$2 stall=${JG_READY_STALL_SECS:-600} every=${JG_READY_STALL_POLL_SECS:-60}
  local record="$STATE/.waiting-timers/.ready-backlog" mark="$STATE/.waiting-timers/.ready-backlog-checked"
  local whyfile="$STATE/.waiting-timers/.ready-backlog-why" why_old
  local rc since='' lanes='' key='' reported=0 last=0 id lead age report reason cond
  case "$stall" in ''|*[!0-9]*|0*) echo "waiting timers: JG_READY_STALL_SECS must be positive decimal seconds" >&2; return 1 ;; esac
  case "$every" in ''|*[!0-9]*) echo "waiting timers: JG_READY_STALL_POLL_SECS must be decimal seconds" >&2; return 1 ;; esac
  declare -F ready_backlog_stall_state >/dev/null || return 0
  [ ! -e "$mark" ] || [ "$(age_of "$mark")" -ge "$every" ] || return 0
  touch "$mark" || return 1
  lead=$(jg_parent_channel_home_id "$JG_HOME") || return 0
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
# more wait source (README "Green PR left unmerged"): once it has stayed so for
# JG_GREEN_PR_SECS, <task>.greenpr is rewritten on every tick and the existing
# per-task ladder takes over. The source clears on a merge (the poll retires
# or the forge answers not open), a new head (the clock re-arms), a pause or
# captain hold on the task, or yolo off. Only GitHub is read; any other forge,
# an unreadable answer, or a missing gh stays quiet. State: .green-pr/<task>
# holds checked, since, head, url; a forge read runs at most every
# JG_GREEN_PR_POLL_SECS, and an answer older than three reads lapses.
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
    if [ -z "$url" ]; then rm -f "$rec" "$STATE/.wait-sources/$id.greenpr"; continue; fi
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
        1) rm -f "$rec" "$STATE/.wait-sources/$id.greenpr"; continue ;;
        *) [ "$checked" -gt 0 ] || continue ;;
      esac
    fi
    # An answer that was never refreshed (the forge stopped answering) lapses.
    if [ $((now - checked)) -le $((every * 3)) ] && [ $((now - since)) -ge "$stall" ]; then
      mkdir -p "$STATE/.wait-sources" \
        && printf 'greenpr: %s is green at %s and unmerged under yolo; merge it (bin/jg-pr-merge.sh) or record a hold with a reason\n' "$url" "${head:0:8}" \
          > "$STATE/.wait-sources/$id.greenpr" || return 1
    else
      rm -f "$STATE/.wait-sources/$id.greenpr"
    fi
  done
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    [ -f "$STATE/${rec##*/}.meta" ] || rm -f "$rec" "$STATE/.wait-sources/${rec##*/}.greenpr"
  done
  return 0
}

jg_wait_timers_definition_timers() {
  "$_JG_WAIT_TIMER_DIR/jg-escalation-workflows.sh" timers 2>/dev/null
}

jg_wait_timers_tick() {
  local escalate=${JG_WAIT_ESCALATE_SECS:-300} card_secs=${JG_WAIT_CARD_SECS:-600}
  local interval=${JG_PROMPT_REALERT_SECS:-600}
  # The owner alert and the pause cadence are the escalation workflow
  # definition's timers, and the owner rung itself is delivered there
  # (bin/jg-escalation-workflows.sh, live on every poll). The two numbers are
  # read from it because the rungs this library still owns measure their offsets
  # from the owner alert: the escalation runs <escalate> seconds from the
  # episode's start and a declared pause rechecks at the pause cadence. Neither
  # number is written down again here.
  local alert paused_alert numbers
  numbers=$(jg_wait_timers_definition_timers) || {
    echo "waiting timers: the escalation workflow definition is unreadable" >&2
    return 1
  }
  alert=$(printf '%s\n' "$numbers" | awk -F '\t' '$1 == "owner" { print $2 }')
  paused_alert=$(printf '%s\n' "$numbers" | awk -F '\t' '$1 == "pause" { print $2 }')
  local meta task backend window session native sessions='|' blocked='|' unknown='|' rows actor=Main lead=''
  local dir="$STATE/.waiting-timers" now record declaration verb signature old since owner parent key misses age reason until bound rc
  local pause_key dkey src source card last wsrc fresh session_id fired every level pending=''
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
    for src in prompt question quota errors silent supervision greenpr; do
      [ -z "$declaration" ] || break
      record="$STATE/.wait-sources/$task.$src"
      [ -f "$record" ] && [ ! -L "$record" ] || continue
      [ "$src" = supervision ] || [ "$(age_of "$record")" -lt "$fresh" ] || continue
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
    if status_is_paused "$declaration" && until=$(status_paused_until "$declaration") && [ "$now" -lt "$until" ]; then
      declaration=''
    fi
    # A captain hold waits on the captain, so a held lane never arms an episode.
    # Checked before the record is read: a check made only once an episode is due
    # would clear it and let the still-declared wait re-arm it on the next poll.
    if [ -n "$declaration" ] && task_captain_call_open "$task"; then
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
    [ "$owner" -gt 1 ] || continue
    if ! status_is_paused "$declaration" && [ "$parent" -eq 0 ] \
      && [ "$((now - owner))" -ge "$((escalate - alert))" ] && [ "$age" -ge "$escalate" ]; then
      if [ -n "$lead" ]; then
        jg_wait_timer_report "blocked [key=$key]: waiting-timer-overdue: $task ($verb, observed ${age}s, since=$since); owning lead has not cleared the wait; Main must unblock or steer the lead; source=[$source]" || continue
        parent=$now
        jg_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" "$misses" "$card" "$last" || return 1
      else
        # The reason line's leading word is the wake kind every consumer
        # classifies by, so it must read "check:" like the kind this row is
        # queued under: a prefix outside that taxonomy classifies as no wake at
        # all, and the escalation then reaches nobody.
        reason="check: waiting-state $task ($verb, observed ${age}s, level=main; Main must unblock it now) id=$key source=[$source]"
        jg_wake_append check "$key-escalation" "$reason" || return 1
        parent=$now
        jg_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" "$misses" "$card" "$last" || return 1
        wake "$reason"
      fi
    fi
    # Only the main home posts a card: what Main cannot settle reaches the captain.
    if [ -z "$lead" ] && ! status_is_paused "$declaration" && [ "$parent" -gt 0 ] && [ "$card" -eq 0 ] && [ "$age" -ge "$card_secs" ]; then
      jg_wait_timer_card "$task" "$key-card" "$verb" "$source" || true
      card=$now
      jg_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" "$misses" "$card" "$last" || return 1
    fi
    # Every rung reached fires again while the wait stays open.
    fired=$owner
    for native in "$parent" "$card" "$last"; do [ "$native" -le "$fired" ] || fired=$native; done
    [ "$last" -eq 1 ] || [ "$((now - fired))" -ge "$every" ] || continue
    last=$now
    jg_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" "$misses" "$card" "$last" || return 1
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
