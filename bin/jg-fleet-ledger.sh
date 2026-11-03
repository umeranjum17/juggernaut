#!/usr/bin/env bash
# jg-fleet-ledger.sh - append records to the opt-in fleet activity ledger.
#
# docs/fleet-ledger.md owns the public record contract (file, events, fields,
# limits). This header owns only the writer mechanics.
#
# Off by default. Every producer guards its call with one file test on the
# home's config/fleet-ledger flag, so while the flag is absent this script is
# never run. It repeats that test so a direct invocation writes nothing.
#
# Producers:
#   bin/jg-brief.sh              appended (in every worker's status command,
#                                right after its unchanged plain append)
#   bin/jg-spawn.sh              dispatched (fresh spawns only, never relaunch)
#   bin/jg-watch.sh              capture, once per poll cycle
#   bin/jg-pr-check.sh           pr_ready (a PR registered for review, not the
#                                merge-time re-record from bin/jg-pr-merge.sh)
#   bin/jg-merge-outcome-lib.sh  merged ... pr (a recorded PR merge)
#   bin/jg-merge-local.sh        merged ... local (a local-only landing)
#   bin/jg-teardown.sh           cleaned_up
#
# Usage:
#   jg-fleet-ledger.sh dispatched <task> <kind> <project> <harness> <model>
#   jg-fleet-ledger.sh pr_ready <task> <url>
#   jg-fleet-ledger.sh merged <task> pr <url>
#   jg-fleet-ledger.sh merged <task> local
#   jg-fleet-ledger.sh cleaned_up <task>
#   jg-fleet-ledger.sh capture
#   jg-fleet-ledger.sh appended <config> <state>/<task>.status
#
# capture appends one task.status record for every complete (newline-ended)
# line added to a state/<task>.status log since that task's byte offset in
# state/.<task>.fleet-ledger-offset. An absent offset reads from byte 0, and a
# log shorter than its offset is re-read from byte 0. A partial last line waits
# for a later capture. Records are appended before the offset is saved, so an
# interrupted capture repeats records rather than losing them. Without any
# grown log, capture returns after one size listing and sources nothing.
# appended captures only that task, so a worker's status line is recorded as
# soon as the worker writes it; the byte offset keeps the per-poll capture from
# recording it again. Its arguments name the home, because a worker has no
# juggernaut environment: the flag lives in <config> and the state directory is
# the status file's directory.
# pr_ready, merged, and cleaned_up first capture their own task, so its status
# records precede them. cleaned_up then deletes the task's offset, because teardown
# retires that status log right after. dispatched deletes any leftover offset
# so a reused task id starts at byte 0 of its fresh log.
# Every write holds state/.fleet-ledger.lock.
#
# Environment: JG_HOME, JG_STATE_OVERRIDE, and JG_CONFIG_OVERRIDE resolve the
# home exactly as the other bin/ scripts do.
#
# Exit status: 0 on success or when off, 2 on a usage error, 1 when a record
# could not be written. Producers ignore a failure so it never changes theirs.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -u
# Byte semantics for offsets and lengths; jq still reads the text as UTF-8.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
LEDGER="$STATE/fleet-ledger.jsonl"
LOCK="$STATE/.fleet-ledger.lock"
TEXT_MAX_CHARS=2000

usage() {
  echo "usage: jg-fleet-ledger.sh dispatched <task> <kind> <project> <harness> <model> | pr_ready <task> <url> | merged <task> pr <url> | merged <task> local | cleaned_up <task> | capture | appended <config> <state>/<task>.status" >&2
  exit 2
}

task_ok() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

cmd=${1:-}
case "$cmd" in
  dispatched) { [ "$#" -eq 6 ] && task_ok "$2"; } || usage ;;
  pr_ready) { [ "$#" -eq 3 ] && task_ok "$2" && [ -n "$3" ]; } || usage ;;
  merged)
    task_ok "${2:-}" || usage
    case "$#:${3:-}" in 4:pr) [ -n "$4" ] || usage ;; 3:local) ;; *) usage ;; esac
    ;;
  cleaned_up) { [ "$#" -eq 2 ] && task_ok "$2"; } || usage ;;
  capture) [ "$#" -eq 1 ] || usage ;;
  appended)
    [ "$#" -eq 3 ] && [ -n "$2" ] || usage
    case "$3" in /*/*.status) ;; *) usage ;; esac
    APPENDED_TASK=${3##*/}
    APPENDED_TASK=${APPENDED_TASK%.status}
    task_ok "$APPENDED_TASK" || usage
    CONFIG=$2
    STATE=${3%/*}
    LEDGER="$STATE/fleet-ledger.jsonl"
    LOCK="$STATE/.fleet-ledger.lock"
    ;;
  *) usage ;;
esac

[ -e "$CONFIG/fleet-ledger" ] || exit 0
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1

offset_path() { printf '%s/.%s.fleet-ledger-offset' "$STATE" "$1"; }

read_offset() { # <task> <out-var>: saved byte offset, 0 when absent or malformed
  local value=0
  { IFS= read -r value < "$STATE/.$1.fleet-ledger-offset"; } 2>/dev/null || value=0
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  printf -v "$2" '%s' "$value"
}

# Print "<task>\t<size>" for every status log whose size differs from its
# saved offset, using one wc call for the whole state directory.
grown_logs() {
  local -a logs=()
  local f size path id saved
  for f in "$STATE"/*.status; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    id=${f##*/}
    task_ok "${id%.status}" || continue
    logs+=("$f")
  done
  [ "${#logs[@]}" -gt 0 ] || return 0
  wc -c -- "${logs[@]}" 2>/dev/null | while read -r size path; do
    case "$path" in "$STATE"/*.status) ;; *) continue ;; esac
    id=${path##*/}
    id=${id%.status}
    read_offset "$id" saved
    [ "$size" = "$saved" ] || printf '%s\t%s\n' "$id" "$size"
  done
}

LIBS_LOADED=0
load_libs() {
  [ "$LIBS_LOADED" = 1 ] && return 0
  # shellcheck source=bin/jg-wake-lib.sh
  . "$SCRIPT_DIR/jg-wake-lib.sh" || return 1
  # shellcheck source=bin/jg-classify-lib.sh
  . "$SCRIPT_DIR/jg-classify-lib.sh" || return 1
  LIBS_LOADED=1
}

# append <event> <task> <jq-object-of-extra-members> [jq --arg pairs...]
append() {
  local event=$1 task=$2 extra=$3 line
  shift 3
  line=$(jq -cn --arg event "$event" --arg task "$task" "$@" \
    "def n: if . == \"\" then null else . end; {v: 1, ts: (now | floor), event: \$event, task: \$task} + ($extra)") \
    || return 1
  printf '%s\n' "$line" >> "$LEDGER"
}

# The status-line grammar belongs to bin/jg-classify-lib.sh; this only projects it.
append_status() { # <task> <status-line>
  local task=$1 line=$2 verb key text
  status_line_verb "$line" verb
  case "$verb" in [a-z]*) case "$verb" in *[!a-z-]*) verb='' ;; esac ;; *) verb='' ;; esac
  key=$(_jg_decision_key "$line" 2>/dev/null) || key=''
  [ "$key" != default ] || key=''
  text=${line#*:}
  append task.status "$task" \
    "{state: (\$state | n), key: (\$key | n), text: \$text[0:$TEXT_MAX_CHARS]}" \
    --arg state "$verb" --arg key "$key" --arg text "$text"
}

capture_task() { # <task>; caller holds the lock
  local task=$1 log offset data complete tail line saved
  log="$STATE/$task.status"
  saved=$(offset_path "$task")
  [ -f "$log" ] && [ ! -L "$log" ] || return 0
  read_offset "$task" offset
  data=$(wc -c < "$log") || return 1
  data=${data//[[:space:]]/}
  [ "$data" -ge "$offset" ] || offset=0
  [ "$data" -gt "$offset" ] || return 0
  # The trailing x keeps a final newline that command substitution would strip.
  data=$(tail -c "+$((offset + 1))" "$log"; printf x) || return 1
  data=${data%x}
  tail=${data##*$'\n'}
  complete=${data%"$tail"}
  [ -n "$complete" ] || return 0
  while IFS= read -r line; do
    [ -n "${line//[[:space:]]/}" ] || continue
    append_status "$task" "$line" || return 1
  done <<< "${complete%$'\n'}"
  offset=$((offset + ${#complete}))
  printf '%s\n' "$offset" > "$saved.tmp" && mv -f "$saved.tmp" "$saved"
}

if [ "$cmd" = capture ]; then
  grown=$(grown_logs) || exit 1
  [ -n "$grown" ] || exit 0
fi

load_libs || exit 1
jg_lock_acquire_wait "$LOCK" || exit 1
trap 'jg_lock_release "$LOCK"' EXIT
rc=0
# shellcheck disable=SC2016 # $names below are jq variables, not shell ones.
case "$cmd" in
  capture)
    while IFS=$'\t' read -r task _; do
      capture_task "$task" || rc=1
    done <<< "$grown"
    ;;
  appended)
    capture_task "$APPENDED_TASK" || rc=1
    ;;
  dispatched)
    rm -f -- "$(offset_path "$2")"
    append task.dispatched "$2" \
      '{kind: ($kind | n), project: ($project | n), harness: ($harness | n), model: ($model | n)}' \
      --arg kind "$3" --arg project "$4" --arg harness "$5" --arg model "$6" || rc=1
    ;;
  pr_ready)
    capture_task "$2" || rc=1
    append task.pr_ready "$2" '{pr: $pr}' --arg pr "$3" || rc=1
    ;;
  merged)
    capture_task "$2" || rc=1
    if [ "$3" = pr ]; then
      append task.merged "$2" '{via: "pr", pr: $pr}' --arg pr "$4" || rc=1
    else
      append task.merged "$2" '{via: "local"}' || rc=1
    fi
    ;;
  cleaned_up)
    capture_task "$2" || rc=1
    append task.cleaned_up "$2" '{}' || rc=1
    [ "$rc" -ne 0 ] || rm -f -- "$(offset_path "$2")"
    ;;
esac
[ "$rc" -eq 0 ] || echo "jg-fleet-ledger: could not record $cmd${2:+ for $2}; the ledger may be missing records" >&2
exit "$rc"
