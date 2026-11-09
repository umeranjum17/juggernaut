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
#   3. A refusal that only needs time (away mode, a red trunk, a held decision) is not the worker's to fix and never comes here.
# State: <MEM>/<task>.<head>.refusal, one line `<first seen epoch> <reason checksum> <last steer epoch> <alerted 0|1>`.
# Needs from the caller: STATE, MEM, FMH, QUIET (set for a silent sweep), and the task's project and branch.

RESTEER_SECS=600
ALERT_SECS=600

# Whether the worker has a steer it has not read yet: that record rings on its own ladder, so a second one adds nothing.
refusal_unread_steer() {  # <task-id>
  compgen -G "$STATE/$1.inbox/*.msg" >/dev/null 2>&1
}

# Usage: lane_refusal_reach <task-id> <head> <project-dir> <branch> <reason>
lane_refusal_reach() {
  local id=$1 head=$2 proj=$3 branch=$4 reason sum f now first rsum steered alerted text
  [ -z "${QUIET:-}" ] || return 0
  reason=$(printf '%s' "$5" | tr '\n' ' ' | cut -c1-1200)
  # A refusal of a head the lane has moved off is history: nobody is steered about it.
  [ "$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null)" = "$head" ] || return 0
  sum=$(printf '%s' "$reason" | cksum | cut -d' ' -f1); f=$MEM/$id.$head.refusal; now=$(date +%s)
  if [ -f "$f" ]; then read -r first rsum steered alerted < "$f" || :; fi
  case ${first:-}:${steered:-}:${alerted:-} in [0-9]*:[0-9]*:[01]) ;; *) first=$now; rsum=$sum; steered=0; alerted=0 ;; esac
  [ "$rsum" = "$sum" ] || { first=$now; steered=0; alerted=0; }
  if [ "$steered" = 0 ] || { [ $(( now - steered )) -ge "$RESTEER_SECS" ] && ! refusal_unread_steer "$id"; }; then
    text="The lander refused your lane $id at head ${head:0:12}: $reason. Fix it in the lane: change the one commit (amend it, never add a second), prove the new head, and report done again. This steer repeats every $(( RESTEER_SECS / 60 )) minutes until the lane's head changes."
    if JG_HOME=$FMH "$FMH/bin/jg-send.sh" "$id" "$text" >/dev/null 2>&1; then steered=$now; fi
  fi
  if [ "$alerted" = 0 ] && [ $(( now - first )) -ge "$ALERT_SECS" ]; then
    echo "trunk-landing: ALERT: $id has sat refused for over $(( ALERT_SECS / 60 )) minutes at head ${head:0:12} and nobody acted: $reason"
    alerted=1
  fi
  printf '%s %s %s %s\n' "$first" "$sum" "$steered" "$alerted" > "$f"
}
