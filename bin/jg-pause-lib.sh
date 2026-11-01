#!/usr/bin/env bash
# bin/jg-pause-lib.sh - one owner of the fleet-pause record reading.
#
# A declared fleet pause silences intake and the timers that intake climbs, and
# nothing else: a signal, stale or blocker wake still fires for a paused home.
# The records are the ones the fleet already keeps - state/.fleet-paused (the
# marker core/fleet-stall/fleet-stall-check reads), data/fleet-pause*.md (the
# order in the primary home) and data/paused-for-juggernaut.md (a home's own
# paused-lane list) - so this reads a pause, it never declares one. Main clears a
# pause by deleting its record, or by writing the lift into the first line: an
# active pause note carries the words "resume rule" further down.
#
# Callers, each reading this rule rather than repeating it:
#   bin/jg-watch.sh                          ready-work intake
#   bin/jg-fleet-heartbeat.sh                a paused home's waits are named as
#                                            paused, never as climbing ones
#   core/wait-timers/bin/jg-wait-timers-lib.sh  the stalled ready backlog
#   core/lead-wake/bin/jg-lead-wake-lib.sh   ready-work intake, lead-wake feature

# 0 when <home> (default $JG_HOME) stands under a declared fleet pause. The
# argument lets one pass ask about a Squad Lead home it is reading.
fleet_paused() {  # [<home>]
  local home=${1:-${JG_HOME:-}} rec heading
  [ -n "$home" ] || return 1
  [ -f "$home/state/.fleet-paused" ] && return 0
  for rec in "$home"/data/fleet-pause*.md "$home/data/paused-for-juggernaut.md"; do
    [ -f "$rec" ] || continue
    heading=$(awk 'NF { print; exit }' "$rec" 2>/dev/null)
    case $heading in
      *[Ll]ift*|*[Rr]esum*|*[Uu]npaus*) continue ;;
    esac
    return 0
  done
  return 1
}
