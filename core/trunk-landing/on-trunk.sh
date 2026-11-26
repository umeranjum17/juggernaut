#!/usr/bin/env bash
# on-trunk.sh - a lane whose head the trunk already holds is never judged again (sourced by trunk-landing.sh and refusal-reach.sh).
#
# A lane head the local trunk holds (an ancestor of the trunk tip) has nothing left to land, so no proof, no refusal and no steer applies
# to it. Two lanes reach that state, and `lane_on_trunk_settle` is the one owner of what each does:
#   from                           to                       how
#   a lane the lander just landed  landed (in flight)       nothing: `jg-trunk.sh land` rebased the lane's commit and moved the branch to
#     (a landing row names this                              it before the run recorded `landed`, and the proof is bound to the head
#     head) while its run lives                              before the rebase. The run ends the lane's cleanup itself.
#   a lane the lander landed,      landed                   the check ends the cleanup the dead run did not (landed_lane), once.
#     its run ended
#   a lane with no commit of its   closed                   its change is already on the trunk, so nothing lands: the lane is cleaned up
#     own (no landing row names                              unforced like a landed one (closed_lane), its waiters resume, and one outbox
#     this head)                                             line says it closed with no landing. Dirty work in its copy refuses the
#                                                            cleanup, as for any lane.
# State: the same `<MEM>/<task>.<head>.state` line `landed ...` that any landed lane carries; the sweep skips a head that has one.
# Needs from the caller: STATE, MEM, DATA_DIR, FMH, run_alive, landed_lane, lane_cleanup, resume_waiters, cleanup_outbox, verdict_tip.

# Whether the trunk holds <head> already: an ancestor of the tip the lander last recorded for the project.
lane_on_trunk() {  # <project dir> <head>
  local tip; tip=$(verdict_tip "$(basename "$1")")
  [ -n "$tip" ] && git -C "$1" merge-base --is-ancestor "$2" "$tip" 2>/dev/null
}

# Whether a landing run of the lane lives now (under any head it has had).
lane_landing_in_flight() {  # <task-id>
  local f l
  for f in "$MEM/$1".*.state; do
    [ -f "$f" ] || continue
    l=$(cat "$f" 2>/dev/null || true)
    case $l in running*) run_alive "$l" && return 0 ;; esac
  done
  return 1
}

# A lane with no commit of its own: cleaned up like a landed one, and said so once.
closed_lane() {  # <task-id> <head>
  local id=$1 head=$2 res
  res=$(lane_cleanup "$id" "$head" "")
  resume_waiters "$id"
  cleanup_outbox "closed $id: no commit of its own, its head ${head:0:12} is already on the local trunk, so no landing was needed; $res"
}

# What the sweep does for a lane whose head the trunk holds (the table in the header).
lane_on_trunk_settle() {  # <task-id> <head>
  local id=$1 head=$2
  if awk -F'\t' -v i="$id" -v h="$head" '$1 == i && $3 == h { f = 1 } END { exit !f }' "$DATA_DIR/trunk-landings.tsv" 2>/dev/null; then
    lane_landing_in_flight "$id" && return 0
    landed_lane "$id" "$head" "on the local trunk (its landing run ended before the cleanup, so the check finished it)"
  else
    closed_lane "$id" "$head"
  fi
}
