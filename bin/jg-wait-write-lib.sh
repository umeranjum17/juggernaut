# shellcheck shell=bash
# jg-wait-write-lib.sh - the one writer of a typed wait and of its resolution. Sourced by bin/jg-wait-write.sh and by every
# producer that opens or closes a wait in a status log (core/agent-cli ask and wait, the answer path of bin/jg-send.sh).
#
# A wait has a kind, and the kind decides what may close it:
#   pause       `paused [at] [key] [wait=<who>] [reason=<word>]: <text>`  a declared wait; the guard checks the closed words.
#   decision    `needs-decision [at] [key]: <text>`                       the worker's own question.
#   owner-call  `needs-decision [at] [key]: captain call, hold <task>: <text>`   the owner's call; the note prefix is the
#               classifier's (`jg-classify.sh human-call-prefix`), so a done, a failed or a restated key never closes it.
# Every wait closes with `resolved [at] [key]: <text>` and only while it is open: a second resolution, and a second opening of
# a wait that is already open as written, write nothing and say so. The classifier (core/classify) is the one reader of what is open.
#
# Needs bin/jg-classify-lib.sh sourced (status_open_decisions, status_open_activities). The self-announced close needs
# bin/jg-wake-lib.sh as well, which the caller has sourced when it passes a state directory.

_JG_WAIT_WRITE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# 0 when <key> (default: the keyless "default") is open in <status-file> as a decision or a declared wait; with a <note>,
# only when the open record says exactly that, so a new question on an open key is a new wait and is written.
jg_wait_is_open() {  # <status-file> <key> [<note>]
  local file=$1 key=$2 open rec home hid rc=0 lane
  # Once the home reads from the item store (slice 8w writes config/item-store-reads), the store answers, whatever the file's
  # size (Y9); a question about the note's exact text, or a store that cannot answer, falls back to folding the file.
  home=${JG_HOME:-$(dirname -- "$(dirname -- "$file")")}
  lane=$_JG_WAIT_WRITE_DIR/../core/item-store/adapters/lane.py
  if [ "$#" -lt 3 ] && [ -e "$home/config/item-store" ] && [ -e "$home/config/item-store-reads" ] && [ -f "$lane" ]; then
    hid=main
    [ ! -f "$home/.jg-squad-lead-home" ] || hid=$(head -n 1 "$home/.jg-squad-lead-home")
    JG_HOME=$home python3 -I "$lane" is-open "$hid" "$(basename -- "$file" .status)" "$key" >/dev/null 2>&1 || rc=$?
    case $rc in 0) return 0 ;; 1) return 1 ;; esac
  fi
  open=$(status_open_decisions "$file"; status_open_activities "$file")
  rec=$(printf '%s\n' "$open" | awk -F'\t' -v k="$key" '$1 == k { print; exit }')
  [ -n "$rec" ] || return 1
  [ "$#" -lt 3 ] || [ "${rec#*$'\t'*$'\t'}" = "$3" ]
}

# Append one line through the guard, which refuses a bad line and writes nothing.
jg_wait_append() {  # <status-file> <line>
  printf '%s\n' "$2" | "$_JG_WAIT_WRITE_DIR/jg-lavish-guard.sh" --append "$1"
}

# jg_wait_open <status-file> <kind> <key|-> <text> [<who> <reason> | <task>]
#   pause: who and reason follow the text; owner-call: the task whose hold the call names follows the text.
# Prints the line it wrote, or `already open: <key>` and writes nothing when the key is open. Returns 0, or 1 on a refusal.
jg_wait_open() {
  local file=$1 kind=$2 key=$3 text=$4 line note tags='' prefix
  [ "$key" = - ] && key=''
  [ -z "$key" ] || tags=" [key=$key]"
  case $kind in
    pause)
      [ -n "${5:-}" ] && [ -n "${6:-}" ] || { echo 'jg-wait-write: a pause needs a who and a reason' >&2; return 1; }
      note=$text
      line="paused [at=$(date +%s)]$tags [wait=$5] [reason=$6]: $text" ;;
    decision) note=$text; line="needs-decision [at=$(date +%s)]$tags: $text" ;;
    owner-call)
      [ -n "${5:-}" ] || { echo 'jg-wait-write: an owner call names the task of its hold' >&2; return 1; }
      prefix=$("$_JG_WAIT_WRITE_DIR/jg-classify.sh" human-call-prefix) || return 1
      note="$prefix$5: $text"
      line="needs-decision [at=$(date +%s)]$tags: $note" ;;
    *) echo "jg-wait-write: unknown wait kind '$kind' (pause, decision, owner-call)" >&2; return 1 ;;
  esac
  if jg_wait_is_open "$file" "${key:-default}" "$note"; then echo "already open: ${key:-default}"; return 0; fi
  jg_wait_append "$file" "$line" || return 1
  printf '%s\n' "$line"
}

# jg_wait_resolve <state|-> <status-file> <key> <text> [<key> <text>...]
# Closes each named wait (`-` is the keyless one) that is still open, in one append. A key that is not open is skipped and named
# (`already resolved: <key>`), so a resolution never fires twice. With a state directory the append is the home's
# own self-announced one (bin/jg-wake-lib.sh): it does not wake the session that wrote it. Returns that append's
# status (0 and 1 appended, 2 failed), or 0 when nothing was open.
jg_wait_resolve() {
  local state=$1 file=$2 key text close_lines=() line rc=0 at=''
  shift 2
  [ "$state" != - ] || at=" [at=$(date +%s)]"  # the self-announced append stamps its own lines
  while [ "$#" -ge 2 ]; do
    key=$1 text=$2; shift 2
    if jg_wait_is_open "$file" "${key/#-/default}"; then
      if [ "$key" = - ]; then close_lines+=("resolved$at: $text"); else close_lines+=("resolved$at [key=$key]: $text"); fi
    else echo "already resolved: ${key/#-/default}"; fi
  done
  [ "${#close_lines[@]}" -gt 0 ] || return 0
  if [ "$state" = - ]; then
    for line in "${close_lines[@]}"; do jg_wait_append "$file" "$line" || return 2; done
  else
    jg_wake_status_append_self_announced "$state" "$file" "${close_lines[@]}" || rc=$?
  fi
  return "$rc"
}
