#!/usr/bin/env bash
# jg-comms-feed.sh - export every message the fleet exchanges as ONE read-only,
# live, append-only JSONL feed, so a Slack-like reader can show the fleet's
# channels the way people read a chat log.
#
# Usage:
#   jg-comms-feed.sh sync [--follow] [--every <seconds>]
#   jg-comms-feed.sh path
#
# sync    Append the messages new since this home's cursor, then update the
#         cursor. --follow repeats that pass without a reload until signalled.
# path    Print the feed file.
#
# Feed: <state>/comms-feed.jsonl (override with JG_COMMS_FEED), one JSON object
# per line, appended in time order and never rewritten:
#   ts       Unix seconds of the exchange
#   home     the home that recorded it
#   channel  a lead's own room (its task id) or "task:<task id>"
#   from/to  the exchanging ends; "main" is this home's lead, "captain" the owner
#   kind     steer, status, reply, board-question, board-answer, parent-channel
#   tag      the "MainNNN [order]" style tag the text carries, else null
#   key      the decision, blocker, or correlation key, else null
#   state    unread or handled where the source records it, else null
#   text     what was said (redacted, capped at 4000 characters)
#
# Sources, all read-only, none of them an auth file, .env, or credential store -
# and the scan opens nothing else, so no such file can be reached by accident:
#   <state>/<task>.inbox/NNN.msg, handled/NNN.msg   steer        unread|handled
#   <state>/*.status                                status       -
#   <state>/parent-replies.status                   parent-channel -
#   <state>/reply-state.tsv#<corr>                  reply        unread|handled
#   <state>/fleet-ledger.jsonl                      steer|status -
#   <board>, <board>.answers.jsonl                  board-question|board-answer
# A lead home is a home carrying a squad_lead identity marker; its parent
# channel is its own report file, while in Main that channel is a squad_lead
# task's status log. Homes scanned: this one plus every local squad_lead task's
# recorded home; a remote home's state is not reachable read-only.
#
# One owner per exchange: a status line is read from its log and its ledger
# task.status twin is skipped, so nothing is reported twice. The ledger adds
# only what a status log never carries - dispatch, PR ready, merge, cleanup.
#
# The cursor is <state>/.comms-feed-cursor, append-only, last entry wins:
# "off" a line log's byte offset, "seq" an inbox's last sequence, "done" a
# one-shot identity, "sig" a whole-file signature. A partial last line waits for
# the next pass, and a pass appends its messages before it saves its offsets, so
# an interrupted pass repeats a message rather than losing one.
# `state` is what the source recorded when the line was written: an append-only
# feed never revises an earlier line.
#
# Wired into the watcher's poll (bin/jg-watch.sh), so the feed is on for every
# install with no flag to set and costs nothing when the sources have not moved.
# Nothing here depends on a Juggernaut home being otherwise configured.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
FEED="${JG_COMMS_FEED:-$STATE/comms-feed.jsonl}"
CURSOR="$STATE/.comms-feed-cursor"
LOCK="$STATE/.comms-feed.lock"
TEXT_MAX=4000
CF_SEP=$'\x1f'
EVERY=${JG_COMMS_FEED_EVERY:-5}
ROWS=
PENDING=''
CF_ALL=''
CF_CURSOR=''
LOCKED=
# shellcheck source=bin/jg-compat.sh
. "$SCRIPT_DIR/jg-compat.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-classify-lib.sh
. "$SCRIPT_DIR/jg-classify-lib.sh"
# shellcheck source=bin/jg-task-inbox-lib.sh
. "$SCRIPT_DIR/jg-task-inbox-lib.sh"
# shellcheck source=bin/jg-pending-reply-lib.sh
. "$SCRIPT_DIR/jg-pending-reply-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}

cf_cleanup() {
  [ -z "$ROWS" ] || rm -f -- "$ROWS"
  [ -z "$LOCKED" ] || jg_lock_release "$LOCK"
}

if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
  cf_mtime() { /usr/bin/stat -f '%m' "$1" 2>/dev/null || date +%s; }
else
  cf_mtime() { stat -c '%Y' "$1" 2>/dev/null || date +%s; }
fi

cf_epoch() {  # <any timestamp> -> Unix seconds
  local s=${1-}
  case "$s" in *.*) s=${s%%.*} ;; esac
  case "$s" in *Z) s=${s%Z} ;; esac
  jg_utc_iso_to_epoch "${s}Z" 2>/dev/null || date +%s
}

# Credential-shaped values only: a provider's own token shape, a value attached
# to a secret-looking name, and a bearer value. Prose that merely says "token"
# keeps its words, so the feed stays readable.
cf_redact() {
  sed -E \
    -e 's/(gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|xox[abposr]-[A-Za-z0-9-]{10,}|(AKIA|ASIA)[A-Z0-9]{12,})/[redacted]/g' \
    -e 's/([Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss]([Ww][Oo][Rr][Dd]|[Ww][Dd]|[Pp][Hh][Rr][Aa][Ss][Ee])|[Aa][Pp][Ii][ _-]?[Kk][Ee][Yy]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll][Ss]?|[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn])([[:space:]]*[=:][[:space:]]*)[^[:space:]]+/\1\3[redacted]/g' \
    -e 's/([Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+)[A-Za-z0-9._~+\/=-]{12,}/\1[redacted]/g'
}

cf_tag() {  # <text> -> "MainNNN [order]" or empty
  local line=${1%%$'\n'*} out=''
  local re_num='^([Mm]ain[A-Za-z0-9]*|[A-Za-z]+[0-9]+)([[:space:]]|$)'
  local re_brk='^\[[A-Za-z0-9._-]+\]'
  if [[ $line =~ $re_num ]]; then
    out=${BASH_REMATCH[1]}
    line=${line:${#out}}
    line=${line#"${line%%[![:space:]]*}"}
  fi
  if [[ $line =~ $re_brk ]]; then
    [ -z "$out" ] || out="$out "
    out="$out${BASH_REMATCH[0]}"
  fi
  printf '%s' "$out"
}

cf_key() {  # <text> -> the [key=<slug>] token's slug, or empty
  local re='\[key=([A-Za-z0-9._-]+)\]'
  if [[ ${1-} =~ $re ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
}

cf_room() {  # <state> <task> -> the channel that exchange belongs to
  if [ -f "$1/$2.meta" ] && grep -qx 'kind=squad_lead' "$1/$2.meta" 2>/dev/null; then
    printf '%s' "$2"
  else
    printf 'task:%s' "$2"
  fi
}

cf_emit() {  # <ts> <home> <channel> <from> <to> <kind> <tag> <key> <state> <text>
  local ts=$1 text json
  case "$ts" in ''|*[!0-9]*) ts=$(cf_mtime "$STATE") ;; esac
  text=$(printf '%s' "${10:0:TEXT_MAX}" | cf_redact)
  json=$(jq -cn --argjson ts "$ts" --arg home "$2" --arg channel "$3" \
    --arg from "$4" --arg to "$5" --arg kind "$6" --arg tag "$7" \
    --arg key "$8" --arg state "$9" --arg text "$text" '
    def n: if . == "" then null else . end;
    {ts: $ts, home: $home, channel: $channel, from: $from, to: $to, kind: $kind,
     tag: ($tag | n), key: ($key | n), state: ($state | n), text: $text}') || return 0
  printf '%s\t%s\n' "$ts" "$json" >> "$ROWS"
}

# One read per pass, in two shapes: CF_ALL carries every row for the membership
# test and the merge, while CF_CURSOR keeps only the keys whose value is read,
# so a home with thousands of one-shot records still answers in constant time.
cf_load_cursor() {
  CF_ALL=''
  CF_CURSOR=''
  [ -f "$CURSOR" ] || return 0
  CF_ALL=$(cat "$CURSOR" 2>/dev/null)
  CF_CURSOR=$(awk -F'\t' '$1 ~ /^(off|seq|sig):/ { print }' <<< "$CF_ALL")
}

cf_cursor() {  # <key> [<out-var>] -> the last recorded value; out-var avoids a subshell
  local k val v=''
  while IFS=$'\t' read -r k val; do
    [ -z "$k" ] || [ "$k" != "$1" ] || v=$val
  done <<< "$CF_CURSOR"
  if [ -n "$PENDING" ]; then
    while IFS=$'\t' read -r k val; do
      [ -z "$k" ] || [ "$k" != "$1" ] || v=$val
    done <<< "$PENDING"
  fi
  if [ "$#" -gt 1 ]; then printf -v "$2" '%s' "$v"; else printf '%s' "$v"; fi
}

cf_has() {  # <key> -> true when it is already recorded, this pass included
  # ponytail: O(n^2) substring scan over the recorded keys, which costs ~21s on a
  # first pass over a board of 2,400 cards and ~10ms per new message after that.
  # An associative set would make it linear, but declare -A needs bash 4 and this
  # repo still runs on stock macOS bash 3.2 (see bin/jg-wake-lib.sh), so the
  # ceiling is paid once per source history rather than carried as a version fork.
  case $'\n'"$CF_ALL" in *$'\n'"$1"$'\t'*) return 0 ;; esac
  return 1
}

cf_defer() {  # <key> <value>; written once this pass's messages are durable
  # The value read from the cursor file ends without a newline ($(cat) strips
  # it), so open a line before the first append or this key would glue itself
  # onto the last recorded one and corrupt both.
  [ -z "$CF_ALL" ] || [ "${CF_ALL: -1}" = $'\n' ] || CF_ALL="$CF_ALL"$'\n'
  PENDING="$PENDING$1"$'\t'"$2"$'\n'
  CF_ALL="$CF_ALL$1"$'\t'"$2"$'\n'
}

# Replace the cursor with the merged view: last value per key, one row per live
# source. Rewritten rather than appended so it never grows without bound.
cf_commit_cursor() {
  local tmp
  [ -n "$PENDING" ] || return 0
  tmp=$(mktemp "${CURSOR}.XXXXXX") || return 1
  if {
    printf '%s' "$CF_ALL"
    printf '%s' "$PENDING"
  } | awk -F'\t' '$1 != "" { v[$1] = $2 } END { for (k in v) printf "%s\t%s\n", k, v[k] }' > "$tmp" &&
    mv -f "$tmp" "$CURSOR"; then
    cf_load_cursor
    PENDING=''
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Print the complete lines a text log gained since the cursor, leaving the byte
# offset consumed in cf_offset. A partial last line waits for the next pass.
cf_new_lines() {  # <path> [<size>]
  local path=$1 off size=${2-} data consumed
  cf_lines=''
  cf_offset=0
  [ -f "$path" ] && [ ! -L "$path" ] || return 0
  cf_cursor "off:$path" off
  case "$off" in ''|*[!0-9]*) off=0 ;; esac
  if [ -z "$size" ]; then
    size=$(wc -c < "$path" 2>/dev/null) || return 0
    size=${size//[[:space:]]/}
  fi
  [ "$size" -ge "$off" ] || off=0
  [ "$size" -gt "$off" ] || return 0
  data=$(tail -c "+$((off + 1))" "$path"; printf x) || return 0
  data=${data%x}
  case "$data" in
    *$'\n') ;;
    *)
      case "$data" in
        *$'\n'*) data=${data%$'\n'*}$'\n' ;;
        *) return 0 ;;
      esac
      ;;
  esac
  consumed=${#data}
  cf_offset=$((off + consumed))
  cf_lines=$data
}

cf_scan_status() {  # <home> <state> <lead-id> <is-lead-home 0|1>
  local home=$1 state=$2 lead=$3 islead=$4 f size sizes id line key ts text kind from to channel
  sizes=$(wc -c -- "$state"/*.status 2>/dev/null)
  while read -r size f; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    id=${f##*/}
    id=${id%.status}
    case "$id" in ''|.*) continue ;; esac
    cf_new_lines "$f" "$size"
    [ -n "$cf_lines" ] || continue
    kind=status
    from=$id
    to=$lead
    channel=$(cf_room "$state" "$id")
    if [ "$islead" = 1 ] && [ "$f" = "$state/parent-replies.status" ]; then
      kind='parent-channel'
      from=$lead
      to=main
      channel=$lead
    elif [ "$islead" = 0 ] && grep -qx 'kind=squad_lead' "$state/$id.meta" 2>/dev/null; then
      kind='parent-channel'
      from=$id
      to=$lead
      channel=$id
    fi
    while IFS= read -r line; do
      [ -n "${line//[[:space:]]/}" ] || continue
      key=$(_jg_decision_key "$line" '' 2>/dev/null) || key=''
      ts=''
      if [[ $line =~ \[at=([0-9]+)\] ]]; then ts=${BASH_REMATCH[1]}; fi
      [ -n "$ts" ] || ts=$(cf_mtime "$f")
      case "$line" in *:*) text=${line#*:} ;; *) text=$line ;; esac
      text=${text#"${text%%[![:space:]]*}"}
      cf_emit "$ts" "$home" "$channel" "$from" "$to" "$kind" \
        "$(cf_tag "$line")" "$key" '' "$text"
    done <<< "$cf_lines"
    cf_defer "off:$f" "$cf_offset"
  done <<< "$sizes"
}

cf_scan_inbox() {  # <home> <state> <lead-id>
  local home=$1 state=$2 lead=$3 dir task seq max first f at body st text
  for dir in "$state"/*.inbox; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    task=${dir##*/}
    task=${task%.inbox}
    case "$task" in ''|.*) continue ;; esac
    cf_cursor "seq:$dir" max
    case "$max" in ''|*[!0-9]*) max=0 ;; esac
    first=$max
    while IFS=$'\t' read -r seq f; do
      [ -n "$f" ] || continue
      at=$(sed -n 's/^at=//p;/^--$/q' "$f" 2>/dev/null | head -n1)
      body=$(jg_task_inbox_body "$f" 2>/dev/null) || body=$(cat "$f" 2>/dev/null)
      case "$f" in "$dir"/handled/*) st=handled ;; *) st=unread ;; esac
      text=$body
      cf_emit "$(cf_epoch "$at")" "$home" "$(cf_room "$state" "$task")" "$lead" "$task" \
        steer "$(cf_tag "$body")" "$(cf_key "$body")" "$st" "$text"
      [ "$seq" -le "$max" ] || max=$seq
    done < <(for f in "$dir"/*.msg "$dir/handled"/*.msg; do
      [ -f "$f" ] || continue
      seq=$(jg_task_inbox_seq_of "${f##*/}") || continue
      [ "$seq" -gt "$max" ] || continue
      printf '%s\t%s\n' "$seq" "$f"
    done | sort -n)
    [ "$max" -eq "$first" ] || cf_defer "seq:$dir" "$max"
  done
}

cf_scan_pending() {  # <home> <state> <lead-id>
  local home=$1 state=$2 lead=$3 corr phase task summary ts bucket st block
  while IFS= read -r corr; do
    [ -n "$corr" ] || continue
    block=$(jg_pending_reply_record_text "$(jg_pending_reply_path "$state" "$corr")")
    [ -n "$block" ] || continue
    phase=$(sed -n 's/^phase=//p' <<<"$block" | tail -1)
    task=$(sed -n 's/^task_id=//p' <<<"$block" | tail -1)
    summary=$(sed -n 's/^request_summary=//p' <<<"$block" | tail -1)
    [ -n "$task" ] || task=$corr
    if [ "$phase" = resolved ]; then
      bucket=resolved st=handled
      ts=$(sed -n 's/^resolved_epoch=//p' <<<"$block" | tail -1)
    else
      bucket=open st=unread
      ts=$(sed -n 's/^created_epoch=//p' <<<"$block" | tail -1)
    fi
    [ -n "${ts//[[:space:]]/}" ] || ts=$(cf_mtime "$(jg_pending_reply_cache "$state")")
    cf_has "done:pending:${home}:${corr}:${bucket}" && continue
    cf_emit "$ts" "$home" "$(cf_room "$state" "$task")" "$task" "$lead" \
      reply '' "$corr" "$st" "$summary"
    cf_defer "done:pending:${home}:${corr}:${bucket}" 1
  done < <(jg_pending_reply_corrs "$state")
}

cf_scan_ledger() {  # <home> <state> <lead-id>
  local home=$1 state=$2 lead=$3 line row ev ts task kind project pr via text
  cf_new_lines "$state/fleet-ledger.jsonl"
  [ -n "$cf_lines" ] || return 0
  while IFS= read -r line; do
    [ -n "${line//[[:space:]]/}" ] || continue
    row=$(printf '%s' "$line" | jq -r '[.event // "", (.ts // 0 | tostring), .task // "",
      .kind // "", .project // "", .pr // "", .via // ""] | join($sep)' --arg sep "$CF_SEP" 2>/dev/null) || continue
    IFS=$CF_SEP read -r ev ts task kind project pr via <<< "$row"
    [ -n "$task" ] || continue
    text=''
    case "$ev" in
      task.dispatched) text="dispatched $kind $project" ;;
      task.pr_ready) text="PR ready $pr" ;;
      task.merged) if [ "$via" = local ]; then text='merged locally'; else text="merged $pr"; fi ;;
      task.cleaned_up) text='cleaned up' ;;
      *) continue ;;
    esac
    text=${text% }
    if [ "$ev" = task.dispatched ]; then
      cf_emit "$ts" "$home" "$(cf_room "$state" "$task")" "$lead" "$task" \
        steer '' '' '' "$text"
    else
      cf_emit "$ts" "$home" "$(cf_room "$state" "$task")" "$task" "$lead" \
        status '' '' '' "$text"
    fi
  done <<< "$cf_lines"
  cf_defer "off:$state/fleet-ledger.jsonl" "$cf_offset"
}

cf_scan_board() {  # <lead-id>; the board is the one sign-off-axi reads
  local lead=$1 board answers sig cursig rows row key filed title filer ts text line
  if [ -n "${SIGN_OFF_HOME:-}" ]; then
    board="${SIGN_OFF_HOME}/.sign-off/decisions.json"
    [ -f "$board" ] || board="${SIGN_OFF_HOME}/decisions.json"
  else
    board="$HOME/.sign-off/decisions.json"
  fi
  [ -f "$board" ] && [ ! -L "$board" ] || return 0
  answers="${board%.json}.answers.jsonl"
  # Answers first: a question reads as handled only once its answer is recorded.
  if [ -f "$answers" ] && [ ! -L "$answers" ]; then
    cf_new_lines "$answers"
    while IFS= read -r line; do
      [ -n "${line//[[:space:]]/}" ] || continue
      row=$(printf '%s' "$line" | jq -r '[.key // "", .answer // "", .label // "", .at // ""] | join($sep)' --arg sep "$CF_SEP" 2>/dev/null) || continue
      IFS=$CF_SEP read -r key text title ts <<< "$row"
      [ -n "$key" ] || continue
      ! cf_has "done:board-answer:$key" || continue
      cf_emit "$(cf_epoch "$ts")" "$JG_HOME" "$lead" captain "$lead" \
        board-answer "$title" "$key" handled "$text"
      cf_defer "done:board-answer:$key" 1
    done <<< "$cf_lines"
    [ -n "$cf_lines" ] && cf_defer "off:$answers" "$cf_offset"
  fi
  sig=$(cf_mtime "$board")-$(wc -c < "$board" | tr -d '[:space:]')
  cf_cursor "sig:$board" cursig
  [ "$cursig" != "$sig" ] || return 0
  rows=$(jq -r '(.items // .decisions // [])[]? | [(.key // ""), (.filed // ""),
    (.title // ""), (.filer // "")] | join($sep)' --arg sep "$CF_SEP" "$board" 2>/dev/null) || rows=''
  while IFS=$CF_SEP read -r key filed title filer; do
    [ -n "$key" ] || continue
    ! cf_has "done:board-question:$key" || continue
    [ -n "$filer" ] || filer=$lead
    if cf_has "done:board-answer:$key"; then text=handled; else text=unread; fi
    cf_emit "$(cf_epoch "$filed")" "$JG_HOME" "$lead" "$filer" captain \
      board-question '' "$key" "$text" "$title"
    cf_defer "done:board-question:$key" 1
  done <<< "$rows"
  cf_defer "sig:$board" "$sig"
}

cf_lead_id() {  # <home> -> its lead's room id
  local marker id
  marker="$(jg_compat_marker "$1")"
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    id=$(cat "$marker" 2>/dev/null)
    case "$id" in ''|.*|*[!A-Za-z0-9._-]*) ;; *) printf '%s' "$id"; return 0 ;; esac
  fi
  printf 'main'
}

cf_scan_home() {  # <home> <state> <lead-id>
  local home=$1 state=$2 lead=$3 islead=0
  [ -d "$state" ] && [ ! -L "$state" ] || return 0
  [ "$lead" = main ] || islead=1
  cf_scan_inbox "$home" "$state" "$lead"
  cf_scan_status "$home" "$state" "$lead" "$islead"
  cf_scan_pending "$home" "$state" "$lead"
  cf_scan_ledger "$home" "$state" "$lead"
}

cf_sync() {
  local meta h lead self
  PENDING=''
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  jg_lock_try_acquire "$LOCK" || return 0
  LOCKED=1
  ROWS=$(mktemp "${TMPDIR:-/tmp}/jg-comms-feed.XXXXXX") || return 1
  cf_load_cursor
  self=$(cd "$JG_HOME" && pwd -P)
  cf_scan_home "$JG_HOME" "$STATE" "$(cf_lead_id "$JG_HOME")"
  while IFS= read -r meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    h=$(sed -n 's/^home=//p' "$meta" 2>/dev/null | tail -1)
    [ -n "$h" ] && [ -d "$h/state" ] || continue
    [ "$(cd "$h" && pwd -P)" != "$self" ] || continue
    lead=${meta##*/}
    cf_scan_home "$h" "$h/state" "${lead%.meta}"
  done < <(grep -lx 'kind=squad_lead' "$STATE"/*.meta 2>/dev/null)
  cf_scan_board "$(cf_lead_id "$JG_HOME")"
  if [ -s "$ROWS" ]; then
    sort -n -s -k1,1 "$ROWS" | cut -f2- >> "$FEED" || return 1
  fi
  [ -z "$PENDING" ] || cf_commit_cursor || return 1
  rm -f -- "$ROWS"
  ROWS=
  jg_lock_release "$LOCK"
  LOCKED=
  return 0
}

case "${1:-sync}" in
  path) printf '%s\n' "$FEED"; exit 0 ;;
  sync) shift || true; FOLLOW=0 ;;
  follow) shift || true; FOLLOW=1 ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --follow) FOLLOW=1 ;;
    --every) shift; [ $# -gt 0 ] || usage; EVERY=$1 ;;
    -*) usage ;;
    *) usage ;;
  esac
  shift
done
case "$EVERY" in ''|*[!0-9]*|0) EVERY=5 ;; esac
trap 'cf_cleanup' EXIT
if [ "$FOLLOW" = 1 ]; then
  trap 'exit 0' INT TERM
  while :; do
    cf_sync || true
    sleep "$EVERY"
  done
fi
cf_sync
