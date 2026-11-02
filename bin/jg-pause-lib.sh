#!/usr/bin/env bash
# bin/jg-pause-lib.sh - one owner of the fleet-pause record reading.
#
# A declared fleet pause silences intake and the timers that intake climbs, and
# nothing else: a signal, stale or blocker wake still fires for a paused home.
# The records are the ones the fleet already keeps - state/.fleet-paused (the
# marker core/fleet-stall/fleet-stall-check reads), data/fleet-pause*.md (the
# order in the primary home) and data/.jg-pause-order.md (a home's own pause
# order) - so this reads a pause, it never declares one. Main clears a pause by
# deleting its record, or by writing the lift into the first line.
#
# A record only counts as a pause when its content declares one: a first line
# that names the pause, and the resume rule further down. A report or a lane
# list that happens to sit under a pause record's name is refused, named by
# fleet_pause_refused_records, and never pauses a home. data/paused-for-juggernaut.md
# is the old name for a home's own order and stays readable for a pause already
# declared there, but that name invites exactly such a report, so new pauses go
# in data/.jg-pause-order.md.
#
# Callers, each reading this rule rather than repeating it:
#   bin/jg-watch.sh                          ready-work intake
#   bin/jg-fleet-heartbeat.sh                a paused home's waits are named as
#                                            paused, never as climbing ones
#   core/wait-timers/bin/jg-wait-timers-lib.sh  the stalled ready backlog
#   core/lead-wake/bin/jg-lead-wake-lib.sh   ready-work intake, lead-wake feature

# 0 when pause record <file> declares a pause rather than reporting something
# else: its first non-empty line names the pause without lifting it, and the
# note carries its resume rule below.
pause_record_declares_pause() {  # <file>
  local heading
  heading=$(awk 'NF { print; exit }' "$1" 2>/dev/null)
  [ -n "$heading" ] || return 1
  case $heading in
    *[Ll]ift*|*[Rr]esum*|*[Uu]npaus*) return 1 ;;
    *[Pp]aus*) ;;
    *) return 1 ;;
  esac
  grep -Eqi 'resume rule|resume order' "$1" 2>/dev/null
}

# 0 when <file> declares the lift of a pause: a first line that names the end,
# such as "# Fleet pause - lifted 2026-10-03T16:54:36Z".
pause_record_is_lifted() {  # <file>
  local heading
  heading=$(awk 'NF { print; exit }' "$1" 2>/dev/null)
  case $heading in
    *[Ll]ift*|*[Rr]esum*|*[Uu]npaus*) return 0 ;;
  esac
  return 1
}

# Every pause record file this home may carry, in read order.
pause_records() {  # <home>
  printf '%s\n' "$1"/data/fleet-pause*.md "$1/data/.jg-pause-order.md" "$1/data/paused-for-juggernaut.md"
}

# 0 when <home> (default $JG_HOME) stands under a declared fleet pause. The
# argument lets one pass ask about a Squad Lead home it is reading.
fleet_paused() {  # [<home>]
  local home=${1:-${JG_HOME:-}} rec
  [ -n "$home" ] || return 1
  [ -f "$home/state/.fleet-paused" ] && return 0
  while IFS= read -r rec; do
    [ -f "$rec" ] || continue
    pause_record_declares_pause "$rec" || continue
    return 0
  done <<EOF
$(pause_records "$home")
EOF
  return 1
}

# One line per pause record file that is present but does not declare a pause,
# naming the file and its first line. A report or a lane list parked under a
# pause record's name is refused, never read as a pause, and never disappears
# without a word: the heartbeat says it out loud instead of reporting the home
# as paused by someone else's file.
fleet_pause_refused_records() {  # [<home>]
  local home=${1:-${JG_HOME:-}} rec heading note
  [ -n "$home" ] || return
  while IFS= read -r rec; do
    [ -f "$rec" ] || continue
    pause_record_declares_pause "$rec" && continue
    pause_record_is_lifted "$rec" && continue
    heading=$(awk 'NF { print; exit }' "$rec" 2>/dev/null)
    if [ -n "$heading" ]; then note="first line: $heading"; else note="it is empty"; fi
    printf '%s is not a pause declaration (%s), so this home is not paused\n' "${rec#"$home"/}" "$note"
  done <<EOF
$(pause_records "$home")
EOF
}
