#!/usr/bin/env bash
# jg-chat.sh - the ONE owner of the fleet chat store: what a message is, which
# thread it belongs to, and how its status moves.
#
# Usage:
#   jg-chat.sh send [--1on1] [--on <ref>] [--link <url>] [--owner <role>]
#                   <lead-id|task-id> <text...>
#   jg-chat.sh read <lead-id|task-id|thread|->      print unread, then mark read
#   jg-chat.sh mark <working|done> <lead-id|task-id|thread|->
#   jg-chat.sh reply <lead-id|task-id|thread|-> <text...>
#   jg-chat.sh log [<thread>] [--json]             the reader
#   jg-chat.sh nudge [--after <seconds>] [--send]  unread past a limit
#   jg-chat.sh note <thread> <from|-> <to|-> <kind> <status|-> <text>
#                                                  (the call sites' writer)
#   jg-chat.sh path                               print the store
#
# STORE. <state>/chat.jsonl (JG_CHAT_STORE), append-only, one JSON object per
# line in the order the messages happened:
#   at     Unix seconds the message was recorded
#   thread "#fleet", a lead's own id, or "task:<task id>" - the room it is in
#   from   who spoke: "captain", a task or lead id, or this home's lead id
#   to     the other end; this home's lead id on a fleet event
#   kind   captain (the owner spoke), agent (an agent spoke, a steer included),
#          status (a status line changed), wake (an event reached a lead)
#   text   what was said, one line, capped at 4000 characters
#   status the state of a captain message: sent, read, working, replied, done;
#          null on an agent, status or wake row, which nobody owes a reply to
#   on, link, owner  only on a captain comment: the element it is on, that
#          element's link, and the agent role assigned to answer it
#   status_at        when each state was reached, {state: epoch}
#   reply_at         the epoch of the agent row that answered it
#
# THREADS belong to the captain: one direct thread per lead id and per worker
# task id, plus the one "#fleet" group thread that carries every agent-to-agent
# event. A lead's thread is its own id and an ordinary worker's is
# "task:<id>", the same room vocabulary bin/jg-comms-feed.sh already exports.
#
# WHY A STORE NEXT TO THE FEED. bin/jg-comms-feed.sh derives its feed by scanning
# state files on a cursor: it can only carry what a scan can reconstruct, and it
# revises nothing. This store is written at the call site the moment the event
# happens - jg-send.sh for a steer, jg-wake-lib.sh for a wake that reaches a
# lead, jg-watch.sh for a status line change, all through `note`, never from a
# second scan - so it is the record a reader may trust for order and for the
# status of the captain's own messages. Every one of those writes is
# best-effort: a chat problem never stalls a send, a wake, or supervision.
#
# CAPTAIN PATH. `send` records the message (sent), records it as the captain's
# intervention for the KPI exactly as a typed ask is recorded, so the tag stays
# automatic, and travels through bin/jg-send.sh to the named agent. --1on1
# interrupts the agent's current turn through bin/jg-control.sh first, so the
# message is read instead of waiting for the turn to end; the agent must be a
# task in this home for that. --on makes the same message a comment on an
# element: one record in the agent's thread carrying the element, its link and
# the answering agent's role.
#
# STATUS MOVES are the agent path's, never a hand edit: `read` moves sent -> read
# (stamped), `mark working` read -> working, `reply` -> replied with the reply
# row attached and reply_at stamped, `mark done` replied -> done. A plain
# message stops at replied; only a comment names an element to finish.
# `nudge` reports what is still unread past a limit, and --send escalates it
# once per message to this home's lead.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
STORE="${JG_CHAT_STORE:-$STATE/chat.jsonl}"
LOCK="$STATE/.chat.lock"
NUDGED="$STATE/.chat-nudged"
TEXT_MAX=4000
# shellcheck source=bin/jg-compat.sh
. "$SCRIPT_DIR/jg-compat.sh"
# jg_lock_acquire_wait/jg_lock_release are the fleet's one lock implementation.
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-board-link-lib.sh
. "$SCRIPT_DIR/jg-board-link-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}

die() {
  printf 'jg-chat: %s\n' "$1" >&2
  exit 1
}

# This home's lead id: the room the home itself speaks in, and the end a fleet
# event is addressed to.
chat_lead() {
  local marker id
  if command -v jg_compat_marker >/dev/null 2>&1; then
    marker=$(jg_compat_marker "$JG_HOME")
  else
    marker="$JG_HOME/.jg-squad-lead-home"
  fi
  if [ -r "$marker" ]; then
    id=$(cat "$marker" 2>/dev/null)
    case "$id" in
      '' | .* | *[!A-Za-z0-9._-]*) ;;
      *)
        printf '%s' "$id"
        return 0
        ;;
    esac
  fi
  printf 'main'
}

# The thread a lead or task id belongs to, so a reader shows the same room the
# export names. An explicit thread, and "-" for this home's own room, pass on.
chat_thread() { # <lead-id|task-id|thread|->
  local meta
  case "$1" in
    '#'* | task:*) printf '%s' "$1" ;;
    -) chat_lead ;;
    *)
      meta="$STATE/$1.meta"
      if [ -f "$meta" ] && grep -qx 'kind=squad_lead' "$meta" 2>/dev/null; then
        printf '%s' "$1"
      else
        printf 'task:%s' "$1"
      fi
      ;;
  esac
}

# The agent a thread belongs to: a fleet row has no single other end.
chat_agent() { # <thread>
  case "$1" in
    '#'*) printf '%s' - ;;
    task:*) printf '%s' "${1#task:}" ;;
    *) printf '%s' "$1" ;;
  esac
}

chat_append() { # <thread> <from|-> <to|-> <kind> <status|-> <text> [<extra-json>]
  local thread=$1 from=$2 to=$3 kind=$4 status=$5 text=$6 extra=${7:-} line rc
  [ -n "$extra" ] || extra='{}'
  case "$kind" in
    captain | agent | status | wake) ;;
    *)
      printf 'jg-chat: unknown kind %s\n' "$kind" >&2
      return 1
      ;;
  esac
  if ! command -v jq >/dev/null 2>&1; then
    printf 'jg-chat: jq is required\n' >&2
    return 1
  fi
  [ "$from" != - ] || from=$(chat_lead)
  [ "$to" != - ] || to=$(chat_lead)
  [ "$status" != - ] || status=''
  text=$(printf '%s' "$text" | tr '\n\r\t' '   ')
  line=$(jq -cn --argjson at "${JG_CHAT_AT:-$(date +%s)}" --arg thread "$thread" --arg from "$from" \
    --arg to "$to" --arg kind "$kind" --arg text "${text:0:$TEXT_MAX}" --arg status "$status" \
    --argjson extra "$extra" '
    {at: $at, thread: $thread, from: $from, to: $to, kind: $kind, text: $text,
     status: (if $status == "" then null else $status end)}
    + (if $status == "" then {} else {status_at: {($status): $at}} end) + $extra') || return 1
  mkdir -p "${STORE%/*}" 2>/dev/null || return 1
  jg_lock_acquire_wait "$LOCK" || return 1
  printf '%s\n' "$line" >> "$STORE"
  rc=$?
  jg_lock_release "$LOCK"
  return "$rc"
}

# Move a thread's captain rows from the states that precede <state>, stamping
# the new state and, when replying, the epoch of the answering row.
chat_mark() { # <thread> <read|working|replied|done> [<reply-epoch>]
  local thread=$1 new=$2 reply=${3:-} from now tmp rc=0
  case "$new" in
    read) from='sent' ;;
    working) from='read' ;;
    replied) from='sent read working' ;;
    done) from='replied' ;;
    *)
      printf 'jg-chat: cannot move a status to %s\n' "$new" >&2
      return 1
      ;;
  esac
  [ -f "$STORE" ] || return 0
  now=$(date +%s)
  jg_lock_acquire_wait "$LOCK" || return 1
  tmp=$(mktemp "${STORE}.XXXXXX") || {
    jg_lock_release "$LOCK"
    return 1
  }
  jq -c --arg thread "$thread" --arg new "$new" --arg from "$from" --arg reply "$reply" \
    --argjson now "$now" '
    .status as $s
    | ($from | split(" ")) as $fs
    | if .thread == $thread and $s != null and ($fs | index($s) != null)
      then .status = $new
        | .status_at = ((.status_at // {}) + {($new): $now})
        | (if $reply == "" then . else .reply_at = ($reply | tonumber) end)
      else . end' "$STORE" > "$tmp" || rc=1
  if [ "$rc" -eq 0 ]; then
    mv -f "$tmp" "$STORE" || rc=1
  fi
  [ "$rc" -eq 0 ] || rm -f -- "$tmp"
  jg_lock_release "$LOCK"
  return "$rc"
}

chat_rows() { # [<thread>] [<jq-filter>] [<jq args>...]
  local thread=${1:-} filter=${2:-.}
  if [ $# -gt 2 ]; then shift 2; else set --; fi
  [ -f "$STORE" ] || return 0
  jq -c --arg thread "$thread" "$filter" "$@" "$STORE"
}

# The reader's one line per message: when, the room, who spoke to whom, what
# kind of event and its status, then the words. One format owner.
chat_render() {
  jq -r '"\(.at)  \(.thread)  \(.from)>\(.to)  \(.kind)\(if .status then "/" + .status else "" end)\(if .on then "  on:" + .on else "" end)  \(.text)"'
}

chat_print() { # [<thread>] [<jq-filter>] [<jq args>...]
  chat_rows "$@" | chat_render
}

# A room as it was said, not as it landed: sorted by the recorded time and, on a
# tie, by arrival, so a replayed or skewed-clock line still reads in place.
chat_log() { # <thread|''>
  [ -f "$STORE" ] || return 0
  jq -c -s --arg thread "${1:-}" 'to_entries
    | map(select($thread == "" or .value.thread == $thread))
    | sort_by([.value.at, .key]) | .[].value' "$STORE"
}

# Captain path: record, count it as the captain's intervention, deliver through
# the one send path. The record is written before delivery exactly as jg-send
# writes its record before it rings: the message survives a failed delivery.
cmd_send() {
  local one_on_one=0 on='' link='' owner='' extra='{}' target text thread
  while :; do
    case "${1:-}" in
      --1on1)
        one_on_one=1
        shift
        ;;
      --on | --link | --owner)
        [ $# -ge 2 ] || usage
        case "$1" in
          --on) on=$2 ;;
          --link) link=$2 ;;
          --owner) owner=$2 ;;
        esac
        shift 2
        ;;
      *) break ;;
    esac
  done
  [ $# -ge 2 ] || usage
  target=$1
  shift
  text=$*
  [ -n "${text//[[:space:]]/}" ] || die 'a captain message needs text'
  thread=$(chat_thread "$target")
  if [ -n "$on" ]; then
    extra=$(jq -cn --arg on "$on" --arg link "$link" --arg owner "$owner" \
      '{on: $on} + (if $link == "" then {} else {link: $link} end)
         + (if $owner == "" then {} else {owner: $owner} end)') ||
      die 'cannot build the comment record'
  fi
  # The KPI tag stays automatic: a board-typed or transcribed captain message is
  # recorded exactly as the prompt hook records a typed one, so the turn-end
  # guard asks for its tag the same way.
  "$SCRIPT_DIR/jg-overwatch-kpi.sh" record -- "$text" >/dev/null 2>&1 || true
  chat_append "$thread" captain "$target" captain sent "$text" "$extra" ||
    die 'cannot record the message; nothing was sent'
  # Interrupt first: an Escape after the doorbell would cancel the turn that was
  # about to read the message.
  if [ "$one_on_one" = 1 ]; then
    "$SCRIPT_DIR/jg-control.sh" "$target" interrupt >/dev/null ||
      die 'recorded, but the interrupt did not reach the agent; send it again without --1on1'
  fi
  JG_CHAT_FROM=captain "$SCRIPT_DIR/jg-send.sh" "$target" "$text" ||
    die 'recorded, but delivery to the agent failed; the record is kept, so steer the agent or resend'
}

cmd_read() {
  local thread
  thread=$(chat_thread "$1")
  chat_print "$thread" 'select(.status == "sent")'
  chat_mark "$thread" read || die 'cannot mark the message read'
}

cmd_reply() {
  local thread text now
  thread=$(chat_thread "$1")
  shift
  text=$*
  [ -n "${text//[[:space:]]/}" ] || die 'a reply needs text'
  jg_board_link_fix "$text" || die 'reply refused: it holds a board link without its access token'
  text=$JG_BOARD_LINK_OUT
  now=$(date +%s)
  chat_append "$thread" "$(chat_agent "$thread")" - agent - "$text" ||
    die 'cannot record the reply'
  chat_mark "$thread" replied "$now" || die 'cannot attach the reply to the message it answers'
}

cmd_nudge() {
  local after=3600 send=0 now key lead thread to at text due rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --after)
        [ $# -ge 2 ] || usage
        after=$2
        shift 2
        ;;
      --send)
        send=1
        shift
        ;;
      *) usage ;;
    esac
  done
  case "$after" in '' | *[!0-9]*) usage ;; esac
  [ -f "$STORE" ] || return 0
  now=$(date +%s)
  lead=$(chat_lead)
  # shellcheck disable=SC2016  # $now/$after are jq variables, not shell ones
  due=$(chat_rows '' 'select(.kind == "captain" and .status == "sent" and .at <= ($now - $after))
    | [.thread, .to, (.at | tostring), .text] | @tsv' \
    --argjson now "$now" --argjson after "$after" 2>/dev/null || true)
  while IFS=$'\t' read -r thread to at text; do
    [ -n "$thread" ] || continue
    key="$at:$thread"
    if [ -f "$NUDGED" ] && grep -qxF -- "$key" "$NUDGED" 2>/dev/null; then continue; fi
    printf 'unread %ss  %s  captain>%s  %s\n' "$((now - at))" "$thread" "$to" "$text"
    [ "$send" -eq 1 ] || continue
    if "$SCRIPT_DIR/jg-send.sh" "$lead" \
      "chat nudge [ticket=$to]: the captain wrote in $thread $((now - at))s ago and it is still unread: $text" \
      >/dev/null 2>&1; then
      if mkdir -p "${NUDGED%/*}" 2>/dev/null; then printf '%s\n' "$key" >> "$NUDGED"; fi
    else
      rc=1
    fi
  done <<< "$due"
  return "$rc"
}

verb=${1:-}
[ $# -gt 0 ] && shift
case "$verb" in
  send)
    [ $# -ge 2 ] || usage
    cmd_send "$@"
    ;;
  read)
    [ $# -eq 1 ] || usage
    cmd_read "$1"
    ;;
  mark)
    [ $# -eq 2 ] || usage
    chat_mark "$(chat_thread "$2")" "$1" || die "cannot move the status to $1"
    ;;
  reply)
    [ $# -ge 2 ] || usage
    cmd_reply "$@"
    ;;
  log)
    thread=''
    json=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --json)
          json=1
          shift
          ;;
        -*)
          usage
          ;;
        *)
          thread=$(chat_thread "$1")
          shift
          ;;
      esac
    done
    if [ "$json" -eq 1 ]; then chat_log "$thread"; else chat_log "$thread" | chat_render; fi
    ;;
  nudge) cmd_nudge "$@" ;;
  note)
    [ $# -eq 6 ] || usage
    chat_append "$@" || die 'cannot record the event'
    ;;
  path) printf '%s\n' "$STORE" ;;
  -h | --help | help) usage ;;
  *) usage ;;
esac
