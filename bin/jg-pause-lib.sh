#!/usr/bin/env bash
# bin/jg-pause-lib.sh - one owner of the fleet-pause record reading.
#
# A declared fleet pause silences intake and the timers that intake climbs, and
# nothing else: a signal, stale or blocker wake still fires for a paused home.
# The records are the ones the fleet already keeps - state/.fleet-paused (the
# marker core/fleet-stall/fleet-stall-check reads), data/fleet-pause*.md (the
# order in the primary home) and data/.jg-pause-order.md (a home's own pause
# order) - so this reads a pause, it never declares one. Main clears a pause by
# deleting its record, or by writing LIFTED into its heading block, in any case.
#
# A record only counts as a pause when its content declares one. A report or a lane
# list that happens to sit under a pause record's name is refused, named by
# fleet_pause_refused_records, and never pauses a home. data/paused-for-juggernaut.md
# is the old name for a home's own order and stays readable for a pause already
# declared there, but that name invites exactly such a report, so new pauses go
# in data/.jg-pause-order.md.
# An active order carries Authority:, Next actor:, Resume rule: (or Resume
# order:) and Recheck: YYYY-MM-DDTHH:MM[:SS]Z. Missing fields or a due/invalid
# recheck keep the stop protected and ask Main to reconcile it through the
# heartbeat; no time or partial condition grants permission to resume.
#
# Callers, each reading this rule rather than repeating it:
#   bin/jg-watch.sh                          ready-work intake
#   bin/jg-fleet-heartbeat.sh                a paused home's waits are named as
#                                            paused, never as climbing ones
#   core/wait-timers/bin/jg-wait-timers-lib.sh  the stalled ready backlog

# Record transitions (one read owner, no automatic writes):
#   absent/report -> active: an explicit pause order is recorded.
#   active -> unreconciled: authority, next actor, resume rule or recheck is
#     absent/invalid, or the recheck is due; the stop still holds.
#   unreconciled -> active: Main reconciles the order and its next review.
#   active/unreconciled -> lifted: the authorized lift is recorded in the
#     heading block, or the record is removed. A partial body update, elapsed
#     time, or a different record's lift cannot perform this transition.
# The heading block is the first nonempty line and any following blank or
# Markdown heading lines, ending at the first body line.
pause_record_heading() {  # <file>
  awk 'NF { if (!seen++) print; else if ($0 ~ /^[[:space:]]*#/) print; else exit }' "$1" 2>/dev/null
}

# 0 when the record still carries a stop, including an incomplete legacy order.
pause_record_declares_pause() {  # <file>
  local heading
  pause_record_is_lifted "$1" && return 1
  heading=$(pause_record_heading "$1" | tr '[:upper:]' '[:lower:]')
  [ -n "$heading" ] || return 1
  case $heading in
    *paus*) ;;
    *) return 1 ;;
  esac
  case $heading in
    *report*|*summary*|*'lane list'*|*'paused lanes'*)
      grep -Eqi 'resume rule|resume order|stop new work' "$1" 2>/dev/null ;;
    *) return 0 ;;
  esac
}

# A lift belongs to this record alone; body text is never a lift declaration.
pause_record_is_lifted() {  # <file>
  local heading
  heading=$(pause_record_heading "$1" | tr '[:upper:]' '[:lower:]')
  case $heading in *lifted*) return 0 ;; esac
  # Keep explicit legacy completion titles readable without treating a later
  # heading about when work can be resumed as a completed lift.
  heading=$(awk 'NF { print tolower($0); exit }' "$1" 2>/dev/null)
  case $heading in
    *resumed*|*unpaused*) return 0 ;;
  esac
  return 1
}

# Read existing order fields without changing their authority or conditions.
pause_record_field() {  # <file> <field-name-regex>
  awk -v key="$2" '{
    line=$0; gsub(/\*\*/, "", line); sub(/^[[:space:]]*[-*]?[[:space:]]*/, "", line)
    if (tolower(line) ~ "^(" key ")[[:space:]]*:") {
      sub(/^[^:]*:[[:space:]]*/, "", line); sub(/[[:space:]]*$/, "", line)
      print line; exit
    }
  }' "$1" 2>/dev/null
}

# Reconciliation never grants permission. Missing legacy fields and a due
# observation name Main's next action through the existing heartbeat cadence.
fleet_pause_unreconciled_records() {  # [<home>]
  local home=${1:-${JG_HOME:-}} rec field value missing review epoch now
  [ -n "$home" ] || return
  now=$(date +%s)
  if [ -f "$home/state/.fleet-paused" ]; then
    printf 'state/.fleet-paused: legacy stop has no condition owner or recheck; Main must reconcile\n'
  fi
  while IFS= read -r rec; do
    [ -f "$rec" ] || continue
    pause_record_declares_pause "$rec" || continue
    missing=''
    for field in authority 'next actor' 'resume rule|resume order' recheck; do
      value=$(pause_record_field "$rec" "$field")
      [ -n "$value" ] || missing="${missing:+$missing, }$field"
    done
    review=$(pause_record_field "$rec" recheck)
    epoch=''
    if [ -n "$review" ]; then
      if ! declare -F jg_utc_iso_to_epoch >/dev/null; then
        # shellcheck source=bin/jg-classify-lib.sh
        . "${BASH_SOURCE[0]%/*}/jg-classify-lib.sh"
      fi
      epoch=$(jg_utc_iso_to_epoch "$review" 2>/dev/null) || missing="${missing:+$missing, }invalid recheck"
    fi
    if [ -n "$missing" ]; then
      printf '%s: missing %s; Main must reconcile\n' "${rec#"$home"/}" "$missing"
    elif [ "$epoch" -le "$now" ]; then
      printf '%s: recheck due %s; Main must reconcile\n' "${rec#"$home"/}" "$review"
    fi
  done <<EOF
$(pause_records "$home")
EOF
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
