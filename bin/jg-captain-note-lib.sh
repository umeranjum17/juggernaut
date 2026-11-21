#!/usr/bin/env bash
# jg-captain-note-lib.sh - the one owner of what counts as an UNHANDLED captain
# inbox note, the must-answer list a session digest and every wake drain print
# first, and the acknowledgement gate that refuses to retire a wake batch which
# still holds such a note.
#
# A captain inbox note (bin/jg-inbox.sh) is UNHANDLED while both hold:
#   - its record is still state/inbox/<id>.note, because `bin/jg-inbox.sh drain
#     --ack <id>` moves it to state/inbox/handled/<id>.note (the drain
#     acknowledgement), and
#   - no answer is recorded at state/inbox/.replies/<id>, which is what
#     `bin/jg-inbox.sh reply <id> ...` writes.
# Two ways to settle a note, one definition. A note that has either is answered
# and never blocks anything.
#
# The list is read from the notes themselves, not from the wake queue, because a
# note whose wake row was already acknowledged would otherwise never surface
# again: that is how a captain's "Yes, remove it" note and two questions from 14
# November sat unanswered for days (Main42437, Main42458).
#
# The gate is scoped to the batch a caller is acknowledging: a note whose check
# row is in that batch and still unhandled refuses the acknowledgement, and the
# rows stay queued for the next drain. bin/jg-wake-drain.sh is the only caller
# that consumes wake rows, so it is the single enforcement point.
#
# Every function takes the state directory first, so a caller that already
# resolved its own state never depends on an ambient variable. Callers source
# this file; they are not run through it.
set -u

# The note-id charset bin/jg-inbox.sh writes and accepts.
jg_captain_note_id_ok() {  # <id>
  case "${1:-}" in
    ''|*/*|*..*|*[[:space:]]*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# jg_captain_note_replied <state> <id>: 0 when an answer is recorded for the note.
jg_captain_note_replied() {  # <state> <id>
  local dir="$1/inbox" id=$2
  [ -e "$dir/.replies/$id" ] || [ -L "$dir/.replies/$id" ]
}

# jg_captain_note_pending <state> <id>: 0 while the note is unanswered and unacknowledged.
jg_captain_note_pending() {  # <state> <id>
  local dir="$1/inbox" id=$2
  jg_captain_note_id_ok "$id" || return 1
  [ -f "$dir/$id.note" ] && [ ! -L "$dir/$id.note" ] || return 1
  ! jg_captain_note_replied "$1" "$id"
}

_jg_captain_note_mtime() {  # <path>: a numeric mtime, 0 when unreadable
  local m
  if command -v jg_path_mtime >/dev/null 2>&1; then
    m=$(jg_path_mtime "$1" 2>/dev/null) || m=
  elif m=$(stat -c %Y "$1" 2>/dev/null); then
    :
  else
    m=$(stat -f %m "$1" 2>/dev/null) || m=
  fi
  case "${m:-}" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s\n' "$m"
}

# jg_captain_note_pending_ids <state>: every unhandled note id, oldest first.
jg_captain_note_pending_ids() {  # <state>
  local dir="$1/inbox" note id
  [ -d "$dir" ] || return 0
  for note in "$dir"/*.note; do
    [ -f "$note" ] && [ ! -L "$note" ] || continue
    id=${note##*/}
    id=${id%.note}
    jg_captain_note_pending "$1" "$id" || continue
    printf '%s\t%s\n' "$(_jg_captain_note_mtime "$note")" "$id"
  done | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2 | cut -f2-
}

# jg_captain_note_recorded_at <state> <id>: the note's own UTC record time, or "unknown".
jg_captain_note_recorded_at() {  # <state> <id>
  local path="$1/inbox/$2.note" at
  at=$(sed -n 's/^at=\([^[:space:]]*\)$/\1/p' "$path" 2>/dev/null | head -n 1) || at=
  case "$at" in
    ''|*[!A-Za-z0-9:._+-]*) printf 'unknown\n' ;;
    *) printf '%s\n' "$at" ;;
  esac
}

# jg_captain_note_summary <state> <id>: the note's first body line, one bounded line.
# A chat note keeps the channel tag bin/jg-inbox.sh wrote, because it says where
# the captain's words came from; only the trailing line break is dropped.
jg_captain_note_summary() {  # <state> <id>
  local path="$1/inbox/$2.note" line
  line=$(awk 'found { if ($0 != "") { print; exit } next } /^--$/ { found = 1 }' "$path" 2>/dev/null) || line=
  line=$(printf '%s' "$line" | tr '\t\r\n' '   ')
  printf '%s\n' "$line"
}

_jg_captain_note_cap() {  # <line> <max-characters>
  local line=$1 max=$2
  if [ "$max" -gt 0 ] && [ "${#line}" -gt "$max" ]; then
    line=${line:0:$((max - 3))}...
  fi
  printf '%s\n' "$line"
}

# jg_captain_notes_must_answer_rows <state> [<total-bytes>] [<item-characters>]:
# the list itself - one line per unhandled note, oldest first - bounded like the
# drain's other sections. Prints nothing when every note is answered.
JG_CAPTAIN_NOTE_ITEM_CHARS=200
JG_CAPTAIN_NOTE_TOTAL_BYTES=2000
jg_captain_notes_must_answer_rows() {  # <state> [<total-bytes>] [<item-characters>]
  local state=$1 total=${2:-$JG_CAPTAIN_NOTE_TOTAL_BYTES} item_chars=${3:-$JG_CAPTAIN_NOTE_ITEM_CHARS}
  local ids id used=0 shown=0 omitted=0 line bytes
  ids=$(jg_captain_note_pending_ids "$state") || return 1
  [ -n "$ids" ] || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    line="  $id (recorded $(jg_captain_note_recorded_at "$state" "$id")): $(jg_captain_note_summary "$state" "$id")"
    line=$(_jg_captain_note_cap "$line" "$item_chars")
    bytes=$(( ${#line} + 1 ))
    if [ $((used + bytes)) -gt "$total" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    printf '%s\n' "$line"
    used=$((used + bytes))
    shown=$((shown + 1))
  done <<EOF
$ids
EOF
  if [ "$omitted" -gt 0 ]; then
    printf 'CAPTAIN NOTES: %d more not shown (byte cap); all of them: bin/jg-inbox.sh list\n' "$omitted"
  fi
  [ "$shown" -gt 0 ] || return 0
  return 0
}

# jg_captain_notes_must_answer <state>: the whole must-answer block a wake drain
# prints first. Nothing at all when every note is answered, which is the common
# case.
jg_captain_notes_must_answer() {  # <state>
  local rows
  rows=$(jg_captain_notes_must_answer_rows "$1") || return 1
  [ -n "$rows" ] || return 0
  printf 'CAPTAIN NOTES - MUST ANSWER FIRST (unanswered captain inbox notes, oldest first; an acknowledgement is refused until each one has an answer or a drain acknowledgement):\n'
  printf '%s\n' "$rows"
  printf 'CAPTAIN NOTES: answer with bin/jg-inbox.sh reply <id> '"'"'<answer>'"'"' (a note left unanswered on purpose is closed with bin/jg-inbox.sh drain --ack <id>), then run the acknowledgement again.\n'
}

# jg_captain_note_ack_batch_ids <state> <queue> <rows-file> <cutoff>: the ids of
# unhandled captain notes whose check row is in the batch being acknowledged -
# kind `check`, key `inbox:<id>`, sequence at or below <cutoff> and named in
# <rows-file> when that file is a readable row list. Mirrors the per-actor row
# scoping bin/jg-wake-drain.sh already applies to every other acknowledgement
# receipt, so an actor is never refused for a row it does not own.
jg_captain_note_ack_batch_ids() {  # <state> <queue> <rows-file> <cutoff>
  local state=$1 queue=$2 rows=${3:-} cutoff=$4 epoch seq kind key payload id
  [ -f "$queue" ] && [ -r "$queue" ] && [ ! -L "$queue" ] || return 0
  case "${cutoff:-}" in ''|*[!0-9]*) return 0 ;; esac
  # shellcheck disable=SC2034  # the row's epoch is read from the queue, not used here
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    [ "$kind" = check ] || continue
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    [ "$seq" -le "$cutoff" ] || continue
    case "$key" in
      inbox:*) id=${key#inbox:} ;;
      *) continue ;;
    esac
    if [ -n "$rows" ] && [ -f "$rows" ] && ! grep -qxF "$seq" "$rows"; then continue; fi
    jg_captain_note_pending "$state" "$id" || continue
    printf '%s\n' "$id"
  done < "$queue" | awk '!seen[$0]++'
}

# jg_captain_note_ack_gate <state> <queue> <rows-file> <cutoff>: 0 when the batch
# may be acknowledged, 1 (with the refusal and the note list on stderr) when it
# still holds an unanswered captain note. Nothing is consumed here; the caller
# owns the lock and leaves every row queued on a refusal.
jg_captain_note_ack_gate() {  # <state> <queue> <rows-file> <cutoff>
  local state=$1 queue=$2 rows=${3:-} cutoff=$4 ids id listed=
  ids=$(jg_captain_note_ack_batch_ids "$state" "$queue" "$rows" "$cutoff") || return 1
  [ -n "$ids" ] || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    listed="$listed$( [ -n "$listed" ] && printf ', ' )$id"
  done <<EOF
$ids
EOF
  printf 'wake drain: ACKNOWLEDGEMENT REFUSED - the batch still holds unanswered captain inbox note(s): %s\n' "$listed" >&2
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf 'wake drain:   %s (recorded %s): %s\n' "$id" \
      "$(jg_captain_note_recorded_at "$state" "$id")" \
      "$(_jg_captain_note_cap "$(jg_captain_note_summary "$state" "$id")" "$JG_CAPTAIN_NOTE_ITEM_CHARS")" >&2
  done <<EOF
$ids
EOF
  printf 'wake drain: every row stays queued. Answer each note with bin/jg-inbox.sh reply <id> '"'"'<answer>'"'"' or close it with bin/jg-inbox.sh drain --ack <id>, then run the same acknowledgement again.\n' >&2
  return 1
}
