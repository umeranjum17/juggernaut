#!/usr/bin/env bash
# refusal-reach.sh - the lander's refusal reaches the lane's own worker, and never sits silent (sourced by trunk-landing.sh).
#
# `report` in trunk-landing.sh tells Overwatch about a refusal once. The worker that owns the lane never saw it, so a refused lane
# waited for a human to notice. `lane_refusal_reach` is called on every sweep for a lane whose CURRENT head is refused for something
# the worker fixes (a proof input missing, or a final refusal: a conflict, a red gate); it owns three rules:
#   1. A steer carrying the refusal text goes to the lane's worker (bin/jg-send.sh, a durable inbox record) the first sweep that sees
#      the refusal, and again every RESTEER_SECS while the head is unchanged and the worker has no unread steer (the inbox's own
#      re-ring ladder owns an unread one). It is keyed by the head, so a head the lane no longer has is never steered, and a new head
#      starts a new record.
#   2. A refusal nobody acted on for ALERT_SECS (the head is unchanged) raises ONE alert line that names the lane and the refusal.
#   3. A refusal that only needs time (away mode, a held decision) is not the worker's to fix and never comes here.
#   4. A refusal that is the lane's own fault (its conflict, or a red its own change caused) for a lane that has NO running agent
#      (stopped at Built, or dead) starts ONE new agent for that head (bin/jg-control.sh relaunch), with the refusal as its first
#      instruction; that note is the steer, so none is sent for the head. A refusal that is not the lane's fault (an environment wait or
#      hook, a try cap the machine hit, a revert, a lock, a cleanup refusal) starts nothing, and nor does a lane whose agent runs.
#      Machine: worker `stopped -> starting`, delivery `returned`; the table is refusal_fault_kind and refusal_agent_stopped below.
# State: <MEM>/<task>.<head>.refusal, one line `<first seen epoch> <reason checksum> <last steer epoch> <alerted 0|1>`;
# <MEM>/<task>.<head>.refusal.relaunched, one line `<epoch> <ok|failed>`, the one new agent that head has had.
# Needs from the caller: STATE, MEM, FMH, QUIET (set for a silent sweep), and the task's project and branch.

RESTEER_SECS=600
ALERT_SECS=600

# Whether the worker has a steer it has not read yet: that record rings on its own ladder, so a second one adds nothing.
refusal_unread_steer() {  # <task-id>
  compgen -G "$STATE/$1.inbox/*.msg" >/dev/null 2>&1
}

# The shared delivery path for a refusal or revert. The caller owns deduplication.
refusal_deliver() {  # <note|steer> <task-id> <message>
  local bin=${REFUSAL_BIN:-$FMH/bin} show current tmp result rc=0
  case $1 in
    note)
      show=$(JG_HOME="$FMH" JG_DATA_OVERRIDE="$DATA_DIR" "$bin/jg-backlog.sh" show "$2" --full) || { printf '%s\n' "$show" | sed 's/^/ticket note: /' >&2; return 1; }
      current=$(printf '%s\n' "$show" | sed -n 's/^  body: //p' | head -1 | perl -MJSON::PP -e 'local $/; my $v = <STDIN>; $v = JSON::PP->new->utf8->allow_nonref->decode($v) if $v =~ /^"/; binmode STDOUT, ":raw"; utf8::encode($v) if utf8::is_utf8($v); print $v') || return 1
      if printf '%s\n' "$current" | grep -Fxq -- "$3"; then return 0; fi
      tmp=$(umask 077; mktemp "$MEM/$2.note-XXXXXX") || return 1
      printf '%s\n\n%s\n' "$current" "$3" > "$tmp"
      result=$(JG_HOME="$FMH" JG_DATA_OVERRIDE="$DATA_DIR" "$bin/jg-backlog.sh" update "$2" --body-file "$tmp") || rc=$?
      rm -f -- "$tmp"
      [ "$rc" -eq 0 ] || printf '%s\n' "$result" | sed 's/^/ticket note: /' >&2
      return "$rc" ;;
    steer) [ ! -f "$STATE/$2.meta" ] || JG_HOME="$FMH" "$bin/jg-send.sh" "$2" "$3" >/dev/null ;;
  esac
}

# Whether a final refusal is the lane's own fault: `lane` for its conflict or a red its own change caused, `other` for everything else.
# A positive list, so a new refusal wording starts no agent until it is named here.
refusal_fault_kind() {  # <reason>
  case $1 in
    *'gave up after'*) echo other ;;  # the machine failed the try cap, whatever the red said
    *' conflicts with '*' in: '*|*'this lane introduced or changed the failure of'*|*'this lane is the red in its batch'*|*"gate 'lint' failed"*|*"gate 'full' failed"*|*"gate 'verify' failed"*) echo lane ;;
    *) echo other ;;
  esac
}

# Whether the lane's agent is provably not running: a verified exit record (jg-control.sh exit, the stop at Built), or the crew state's
# own positive evidence that the agent is gone. An unknown reading is not proof, so it starts nothing.
refusal_agent_stopped() {  # <task-id>
  local bin=${REFUSAL_BIN:-$FMH/bin}
  [ ! -s "$STATE/$1.exit" ] || return 0
  JG_HOME="$FMH" "$bin/jg-crew-state.sh" "$1" 2>/dev/null | grep -Eq 'agent gone|agent not running|backend target gone'
}

# One new agent for a refused head, the refusal as its first instruction. Returns 0 only when the relaunch succeeded.
refusal_relaunch() {  # <task-id> <note>
  local bin=${REFUSAL_BIN:-$FMH/bin}
  [ -f "$STATE/$1.meta" ] || return 1
  JG_HOME="$FMH" "$bin/jg-control.sh" "$1" relaunch --note "$2" >/dev/null
}

# Usage: lane_refusal_reach <task-id> <head> <project-dir> <branch> <reason>
lane_refusal_reach() {
  local id=$1 head=$2 proj=$3 branch=$4 reason sum f now first rsum steered alerted text note limit=1200
  [ -z "${QUIET:-}" ] || return 0
  [ "${6:-}" != final ] || limit=300
  reason=$(printf '%s' "$5" | tr '\n' ' ' | cut -c1-"$limit")
  reason=${reason%%; full log:*}
  if [[ $reason =~ \ conflicts\ with\ [^\ ]+\ \(([0-9a-f]+)\)\ in:\  ]]; then reason=${reason/ (${BASH_REMATCH[1]}) in: / in: }; fi
  # A refusal of a head the lane has moved off is history: nobody is steered about it.
  [ "$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null)" = "$head" ] || return 0
  sum=$(printf '%s' "$reason" | cksum | cut -d' ' -f1); f=$MEM/$id.$head.refusal; now=$(date +%s)
  jg_lock_try_acquire "$f.lock" || return 0
  if [ "$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null)" != "$head" ]; then
    jg_lock_release "$f.lock"; return 0
  fi
  if [ -f "$f" ]; then read -r first rsum steered alerted < "$f" || :; fi
  case ${first:-}:${steered:-}:${alerted:-} in [0-9]*:[0-9]*:[01]) ;; *) first=$now; rsum=$sum; steered=0; alerted=0 ;; esac
  [ "$rsum" = "$sum" ] || { first=$now; steered=0; alerted=0; }
  note=$f.noted
  if [ "${6:-}" = final ] && [ "$(cat "$note" 2>/dev/null)" != "$sum" ]; then
    if refusal_deliver note "$id" "$reason"; then
      printf '%s\n' "$sum" > "$note"
    else echo "warning: could not add the refusal note to $id" >&2; fi
  fi
  text="The lander refused your lane $id at head ${head:0:12}: $reason. Fix it in the lane: change the one commit (amend it, never add a second), prove the new head, and report done again. This steer repeats every $(( RESTEER_SECS / 60 )) minutes until the lane's head changes."
  if [ "${6:-}" = final ] && [ ! -e "$f.relaunched" ] && [ "$(refusal_fault_kind "$5")" = lane ] && refusal_agent_stopped "$id"; then
    if refusal_relaunch "$id" "$text"; then printf '%s ok\n' "$now" > "$f.relaunched"; steered=$now
    else printf '%s failed\n' "$now" > "$f.relaunched"; echo "warning: could not start a new agent for $id: its refusal is steered instead" >&2; fi
  fi
  if [ "$steered" = 0 ] || { [ $(( now - steered )) -ge "$RESTEER_SECS" ] && ! refusal_unread_steer "$id"; }; then
    if refusal_deliver steer "$id" "$text"; then steered=$now; fi
  fi
  if [ "$alerted" = 0 ] && [ $(( now - first )) -ge "$ALERT_SECS" ]; then
    echo "trunk-landing: ALERT: $id has sat refused for over $(( ALERT_SECS / 60 )) minutes at head ${head:0:12} and nobody acted: $reason"
    alerted=1
  fi
  printf '%s %s %s %s\n' "$first" "$sum" "$steered" "$alerted" > "$f"
  jg_lock_release "$f.lock"
}
