#!/usr/bin/env bash
# The ladder's known next steps (core/wait-timers/README.md "Known next steps").
# A stuck state names its owner, and the ladder itself takes the owner's automatic
# steps, in the watcher, with no model turn. When they are spent the wait goes to
# the next owner: "lead" hands it to this home's own owner rung (the lead, or Main
# in the main home), and the Main rung after that is unchanged. A stuck state
# with no row here climbs the ladder as before.
#
# JG_WAIT_OWNER_TABLE is the one table, read by jg_wait_action_next:
#   state   the wait it matches (jg_wait_action_state)
#   owner   who clears it first
#   steps   the automatic steps, in order (jg_wait_action_take)
#   next    the owner after the steps
#
#   critic: a deep Recon's open needs-decision naming its draft ready for its
#     critic, with that critic recorded in this home as <task>-critic. forward
#     steers the critic to the draft and closes the decision; a critic that
#     started or reported after the draft already has it, so it is only closed.
#   silent: the silent wait source, on a worker whose own record declares no
#     wait and holds no open decision. ring is one steer asking for its state;
#     relaunch is stuck-operator recovery's bin/jg-control.sh relaunch, detached.
JG_WAIT_OWNER_TABLE='critic	critic	forward	lead
silent	worker	ring,relaunch	lead'
#
# Sidecar state/.waiting-timers/.acted/<task>: state, time of the last step, the
# steps taken (comma-joined), and the time of the first step. It outlives the episode on purpose: a ring
# changes the pane, so a silent wait clears and later re-arms, and this record is
# how the next episode knows the ring is spent. A status line written after the
# last step is progress and ends the record, as does the task's removal.
# Sourced by jg-wait-timers-lib.sh inside the watcher, which supplies STATE,
# JG_HOME, age_of, jg_meta_get and the status classifier.

# Load the sidecar into WAIT_ACT_STATE, WAIT_ACT_AT, WAIT_ACT_STEPS and
# WAIT_ACT_FIRST, first
# dropping a record that progress or the task's removal has ended.
jg_wait_action_read() {  # <task> <now>
  local file="$STATE/.waiting-timers/.acted/$1" st
  WAIT_ACT_STATE='' WAIT_ACT_AT=0 WAIT_ACT_STEPS='' WAIT_ACT_FIRST=0
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  IFS=$'\t' read -r WAIT_ACT_STATE WAIT_ACT_AT WAIT_ACT_STEPS WAIT_ACT_FIRST < "$file" || WAIT_ACT_STATE=''
  case "$WAIT_ACT_AT" in ''|*[!0-9]*) WAIT_ACT_STATE='' ;; esac
  case "$WAIT_ACT_FIRST" in ''|*[!0-9]*) WAIT_ACT_FIRST=$WAIT_ACT_AT ;; esac
  st=0
  [ ! -f "$STATE/$1.status" ] || st=$(($2 - $(age_of "$STATE/$1.status")))
  if [ -z "$WAIT_ACT_STATE" ] || [ ! -f "$STATE/$1.meta" ] || [ "$st" -gt "$WAIT_ACT_AT" ]; then
    rm -f "$file"
    WAIT_ACT_STATE='' WAIT_ACT_AT=0 WAIT_ACT_STEPS='' WAIT_ACT_FIRST=0
  fi
}

# Drop the sidecars of tasks this home no longer records.
jg_wait_actions_prune() {
  local file
  for file in "$STATE"/.waiting-timers/.acted/*; do
    [ -f "$file" ] || continue
    case "$file" in *.log) file=${file%.relaunch.log} ;; esac
    [ -f "$STATE/${file##*/}.meta" ] || rm -f "$file" "$file.relaunch.log"
  done
}

# The critic a deep Recon's draft-ready decision waits for, on stdout.
jg_wait_action_critic_of() {  # <task> <declaration>
  local critic="$1-critic"
  [ "$(jg_meta_get "$STATE/$1.meta" kind)" = scout ] || return 1
  printf '%s' "$2" | grep -qiE 'draft.*ready for .*critic' || return 1
  [ -f "$STATE/$critic.meta" ] && [ ! -L "$STATE/$critic.meta" ] || return 1
  [ "$(jg_meta_get "$STATE/$critic.meta" kind)" = scout ] || return 1
  printf '%s\n' "$critic"
}

# A silent worker the ladder may ring: not a lead, no open decision of its own and
# no declared wait, so it is not waiting on anyone; it went quiet mid-task.
jg_wait_action_silent_ok() {  # <task>
  [ "$(jg_meta_get "$STATE/$1.meta" kind)" != squad_lead ] || return 1
  [ -z "$(status_own_open_decisions "$STATE/$1.status")" ] || return 1
  [ -z "$(status_declared_wait_line "$STATE/$1.status")" ]
}

# The table state of this wait on stdout, or 1 when it has no row.
jg_wait_action_state() {  # <task> <wait source> <verb> <decision key> <declaration>
  case "$2" in
    silent) jg_wait_action_silent_ok "$1" && echo silent ;;
    '') [ "$3" = needs-decision ] && [ -n "$4" ] && jg_wait_action_critic_of "$1" "$5" >/dev/null && echo critic ;;
    *) return 1 ;;
  esac
}

# The next step for this wait in WAIT_ACT_NEXT (its table state in
# WAIT_ACT_NEXT_STATE): the first table step not yet taken, then the next owner;
# 1 when the wait has no row or its row is spent.
jg_wait_action_next() {  # <task> <now> <wait source> <verb> <decision key> <declaration>
  local row_state row step steps next
  WAIT_ACT_NEXT='' WAIT_ACT_NEXT_STATE=''
  row_state=$(jg_wait_action_state "$1" "$3" "$4" "$5" "$6") || return 1
  row=$(printf '%s\n' "$JG_WAIT_OWNER_TABLE" | awk -F '\t' -v s="$row_state" '$1 == s { print $3 "," $4; exit }')
  [ -n "$row" ] || return 1
  jg_wait_action_read "$1" "$2"
  steps=,
  [ "$WAIT_ACT_STATE" != "$row_state" ] || steps=",$WAIT_ACT_STEPS,"
  IFS=, read -ra next <<< "$row"
  for step in "${next[@]}"; do
    # shellcheck disable=SC2034 # Read by the tick in jg-wait-timers-lib.sh.
    case "$steps" in *",$step,"*) ;; *) WAIT_ACT_NEXT=$step WAIT_ACT_NEXT_STATE=$row_state; return 0 ;; esac
  done
  return 1
}

# The steps taken on this wait, for a report that climbs past them and for the
# ledger row of one that cleared: the record's steps when its last step falls in
# this episode (at or after <since>). It reads without dropping, because the
# progress that ends the record is also what clears the wait being reported.
# With "first", the time of the first step instead.
jg_wait_action_spent() {  # <task> <since> [first]
  local file="$STATE/.waiting-timers/.acted/$1" at steps first
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  IFS=$'\t' read -r _ at steps first < "$file" || return 0
  case "$at" in ''|*[!0-9]*) return 0 ;; esac
  case "$first" in ''|*[!0-9]*) first=$at ;; esac
  [ "$at" -ge "$2" ] || return 0
  if [ "${3:-}" = first ]; then printf '%s' "$first"; else printf '%s' "${steps//,/, }"; fi
}

_jg_wait_action_send() {  # <jg-send arguments...>
  JG_HOME="$JG_HOME" "$_JG_WAIT_TIMER_DIR/jg-send.sh" "$@" >/dev/null
}

# Forward the draft, or note that the critic already has it, then close the
# decision through jg-send's answer path. Once the critic holds the draft the
# step counts as taken even when the close fails: the open decision then climbs
# the ladder with the forward named, and the draft is never sent twice.
_jg_wait_action_forward() {  # <task> <decision key> <declaration> <now>
  local critic note line at spawn answer rc=0
  critic=$(jg_wait_action_critic_of "$1" "$3") || return 1
  note=${3#*: }
  # The time the draft was declared: the decision's own line, not the episode,
  # which can re-arm after the critic started.
  line=$(grep -F -- "${note:0:80}" "$STATE/$1.status" 2>/dev/null | tail -n 1)
  at=$(status_line_at_epoch "$line" 2>/dev/null) || at=$4
  spawn=$(jg_meta_get "$STATE/$critic.meta" spawn_gen); spawn=${spawn#s}; spawn=${spawn%%.*}
  case "$spawn" in ''|*[!0-9]*) spawn=0 ;; esac
  if [ "$spawn" -gt "$at" ] \
    || { [ -f "$STATE/$critic.status" ] && [ $(($4 - $(age_of "$STATE/$critic.status"))) -gt "$at" ]; }; then
    answer="The critic $critic already has this draft: it started or reported after you declared it. Wait for its round; there is nothing to do now."
  else
    _jg_wait_action_send "$critic" "Recon $1 declared its draft ready for your next round: $note. Read that draft now, write your next critic round, and report as your brief says." || return 1
    answer="Your draft is forwarded to the critic $critic for its next round. Wait for its gaps; there is nothing to do now."
  fi
  _jg_wait_action_send "$1" --resolve-key "$2" "$answer" || rc=$?
  [ "$rc" -eq 0 ] || echo "waiting timers: $1's draft reached $critic, but closing its decision $2 failed (code $rc)" >&2
}

_jg_wait_action_ring() {  # <task> <silent seconds>
  _jg_wait_action_send "$1" "You have written no status line and shown no new output for at least $(($2 / 60 + ${JG_SILENT_SECS:-900} / 60)) minutes. Append a status line now that says where you are (working, blocked or paused, as your brief says), then carry on with the task."
}

# Stuck-operator recovery's relaunch, owned by bin/jg-control.sh. It stops the old
# agent and starts a new one, which outlasts a poll, so it runs detached and its
# outcome goes to a log beside the sidecar; a failed relaunch leaves the wait
# open, and the next rung reaches Main with both steps named.
_jg_wait_action_relaunch() {  # <task>
  local ctl="$_JG_WAIT_TIMER_DIR/jg-control.sh" log="$STATE/.waiting-timers/.acted/$1.relaunch.log" note detach=()
  [ -x "$ctl" ] || return 1
  note="The watcher relaunched you: you wrote no status line and showed no new output, and a steer asking for your state went unanswered. Your local copy and commits are kept. Read your steering inbox, check git status and git log, then continue the task from where it stopped."
  ! command -v setsid >/dev/null 2>&1 || detach=(setsid)
  # shellcheck disable=SC2016 # The child shell expands its positional parameters.
  ( JG_HOME="$JG_HOME" nohup ${detach[@]+"${detach[@]}"} sh -c '"$1" "$2" relaunch --note "$3"; echo "relaunch exit=$?"' \
      jg-wait-relaunch "$ctl" "$1" "$note" </dev/null >"$log" 2>&1 & ) || return 1
}

# Take <step> on a wait in table <state>. 0 records it in the sidecar; 1 means it
# could not be taken, and the caller lets the rung fire as it would for a wait
# with no row. "lead" has no action here: the caller hands the wait to its owner
# rung.
jg_wait_action_take() {  # <task> <state> <step> <now> <decision key> <declaration> <age>
  local file="$STATE/.waiting-timers/.acted/$1" steps='' at first=''
  jg_wait_action_read "$1" "$4"
  [ "$WAIT_ACT_STATE" != "$2" ] || { steps=$WAIT_ACT_STEPS first=$WAIT_ACT_FIRST; }
  case "$3" in
    forward) _jg_wait_action_forward "$1" "$5" "$6" "$4" || return 1 ;;
    ring) _jg_wait_action_ring "$1" "$7" || return 1 ;;
    relaunch) _jg_wait_action_relaunch "$1" || return 1 ;;
    lead) ;;
    *) return 1 ;;
  esac
  # Stamped once the step is done, so the answer line a forward appends is not
  # read as the worker's own progress.
  at=$(date +%s) || at=$4
  mkdir -p "${file%/*}" \
    && printf '%s\t%s\t%s\t%s\n' "$2" "$at" "${steps:+$steps,}$3" "${first:-$at}" > "$file.tmp.$$" \
    && mv "$file.tmp.$$" "$file" || echo "waiting timers: $1's $3 step was taken but not recorded" >&2
  return 0
}
