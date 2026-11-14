#!/usr/bin/env bash
# jg-context-load.sh - one number per role for what a fleet session loads, and the ceiling that holds it.
#
# Usage:
#   jg-context-load.sh check                              each ceiling against its measure or latest reading
#   jg-context-load.sh cap <name>                         the ceiling value of one line
#   jg-context-load.sh read <transcript.jsonl> <role>     record the first call of a Claude Code session
#   jg-context-load.sh record <role> <item> <value> [unit] [date]   record one reading by hand
#   jg-context-load.sh --help
#
# The ceilings are the `ctx-<role-or-surface>-<item>` lines of defaults/token-caps (config/token-caps
# overrides one home), which also own the unit and the reason of each. This script is the one reader
# of them: bin/jg-brief-lint.sh takes its brief budget here and bin/jg-startup-growth-check.sh calls
# `check` once a day.
#
# `check` prints one line per ceiling and exits 1 when any is over:
#   ok|over|none <name> <value> <ceiling> <source>
# A ceiling whose item the tree can measure (the files named in measure() below) is measured now. Any
# other is a reading: the newest row for it in data/context-load.tsv, or `none` when there is no row.
# A slice that lowers a number lowers its line in defaults/token-caps in its own commit.
#
# `read` and `record` append `<date> <role> <item> <value> <unit> <source>` (TAB-separated) to
# data/context-load.tsv, at most one row per role, item and day: a repeat the same day changes nothing.
# `read` takes the first model call's tokens (ctx-<role>-first-call, tok) and the bytes of the first
# request's tool schemas (ctx-<role>-tool-schemas, B) from the harness's own transcript. A role is
# worker, lead or main.
# Exit 0 clean, 1 a ceiling over, 2 a bad argument or an unreadable file.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
CONFIG_DIR="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
DATA_DIR="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
LOG="$DATA_DIR/context-load.tsv"
DEFAULT_CAPS="$SCRIPT_DIR/../defaults/token-caps"

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }
bad() { echo "jg-context-load: $*" >&2; exit 2; }

# The last `<name> <positive integer>` line of the home's file, else the shared default.
cap_of() {  # <name>
  local file val
  for file in "$CONFIG_DIR/token-caps" "$DEFAULT_CAPS"; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    val=$(awk -v n="$1" '$1 == n && $2 ~ /^[0-9]+$/ && $2 > 0 { v = $2 } END { if (v != "") print v }' "$file")
    [ -z "$val" ] || { printf '%s\n' "$val"; return 0; }
  done
  return 1
}

# Every ctx- line name, the home's first so an override of a line the default lacks is still checked.
cap_names() {
  local file
  for file in "$CONFIG_DIR/token-caps" "$DEFAULT_CAPS"; do
    [ -f "$file" ] && [ ! -L "$file" ] && awk '$1 ~ /^ctx-/ { print $1 }' "$file"
  done | awk '!seen[$0]++'
}

# What the tree itself measures, in bytes. Today both lines are the one contract file; TC4b points the
# supervisor line at the file the contract moves to.
measure() {  # <name>
  case "$1" in
    ctx-agents-md|ctx-supervisor-contract)
      [ -f "$JG_ROOT/AGENTS.md" ] || return 1
      wc -c < "$JG_ROOT/AGENTS.md" | tr -d '[:space:]' ;;
    *) return 1 ;;
  esac
}

latest_reading() {  # <name>
  [ -f "$LOG" ] || return 1
  awk -F '\t' -v n="$1" '$3 == n && $4 ~ /^[0-9]+$/ { v = $4 } END { if (v != "") print v }' "$LOG" | grep .
}

check() {
  local name ceiling value source status=0
  while IFS= read -r name; do
    ceiling=$(cap_of "$name") || continue
    if value=$(measure "$name"); then source=measured
    elif value=$(latest_reading "$name"); then source=reading
    else printf 'none %s - %s no-reading\n' "$name" "$ceiling"; continue; fi
    if [ "$value" -gt "$ceiling" ]; then
      printf 'over %s %s %s %s\n' "$name" "$value" "$ceiling" "$source"; status=1
    else
      printf 'ok %s %s %s %s\n' "$name" "$value" "$ceiling" "$source"
    fi
  done < <(cap_names)
  return $status
}

role_ok() { case "$1" in worker|lead|main) ;; *) bad "role is worker, lead or main, not '$1'" ;; esac; }

record() {  # <role> <item> <value> <unit> <date> <source>
  role_ok "$1"
  [[ $3 =~ ^[0-9]+$ ]] || bad "a reading is a whole number, not '$3'"
  mkdir -p "$DATA_DIR" || bad "cannot make $DATA_DIR"
  if [ -f "$LOG" ] && awk -F '\t' -v d="$5" -v r="$1" -v i="$2" '$1 == d && $2 == r && $3 == i { f = 1 } END { exit !f }' "$LOG"; then
    echo "already read: $1 $2 on $5"; return 0
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$5" "$1" "$2" "$3" "$4" "$6" >> "$LOG" || bad "cannot write $LOG"
  echo "recorded: $1 $2 $3 $4 on $5"
}

read_transcript() {  # <transcript> <role>
  local file=$1 role=$2 tokens tools today
  role_ok "$role"
  [ -f "$file" ] && [ -r "$file" ] || bad "cannot read $file"
  command -v jq >/dev/null 2>&1 || bad "jq is needed to read a transcript"
  tokens=$(jq -rs '[.[] | select(.type == "assistant" and .message.usage != null)][0].message.usage
    | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))' "$file" 2>/dev/null)
  [[ $tokens =~ ^[0-9]+$ ]] || bad "$file holds no model call with usage"
  tools=$(jq -rs '[.[] | select(.type == "api-request-shape")][0].shape.tools // [] | tojson | length' "$file" 2>/dev/null)
  today=${JG_CONTEXT_LOAD_DATE:-$(date -u +%Y-%m-%d)}
  record "$role" "ctx-$role-first-call" "$tokens" tok "$today" "$(basename "$file")"
  [[ $tools =~ ^[0-9]+$ ]] && [ "$tools" -gt 2 ] && record "$role" "ctx-$role-tool-schemas" "$tools" B "$today" "$(basename "$file")"
  echo "$role first call: $tokens tokens"
}

case "${1:-}" in
  check) [ $# -eq 1 ] || bad "check takes no argument"; check ;;
  cap) [ $# -eq 2 ] || bad "cap takes one name"; cap_of "$2" || { echo "jg-context-load: no ceiling named $2" >&2; exit 1; } ;;
  read) [ $# -eq 3 ] || bad "read takes a transcript and a role"; read_transcript "$2" "$3" ;;
  record) [ $# -ge 4 ] && [ $# -le 6 ] || bad "record takes a role, an item, a value, and optionally a unit and a date"
    record "$2" "$3" "$4" "${5:-tok}" "${6:-${JG_CONTEXT_LOAD_DATE:-$(date -u +%Y-%m-%d)}}" hand ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
