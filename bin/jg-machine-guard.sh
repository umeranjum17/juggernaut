#!/usr/bin/env bash
# jg-machine-guard.sh - the one call a writer makes before it moves a record along a machine edge, and the
# per-machine flip from shadow to refusal.
#
# Usage:
#   jg-machine-guard.sh edge <machine> <from|-> <to> [<id>]   judge one move (`-`: the record is new); exit 0 allowed, exit 1 refused, exit 2 usage
#   jg-machine-guard.sh flip <machine> <seconds>     list the machine in config/machine-enforce, only when quiet
#   jg-machine-guard.sh enforced <machine>           exit 0 when the machine is listed in config/machine-enforce, else 1
#
# Shadow is the default. An illegal move (not a table edge, a state the table lacks, and not in
# core/machines/tables/known-baseline.tsv) is appended to data/machine-shadow.log as
# `<epoch> TAB <machine> TAB <from> TAB <to> TAB shadow` and allowed. A machine named on a line of
# config/machine-enforce is enforced: the same move is logged as `refused`, explained on stderr, and exits 1.
# Exit 1 is the only refusal. A guard failure (no table, a table that fails its lint, a log that cannot be
# written) is logged as `error` where it can be and exits 0, so a broken guard never fails the writer.
# A legal move is appended, with the record's id when the writer gave one, to the one move log of every machine,
# data/machine-moves.log: `<epoch> TAB <machine> TAB <id> TAB <from> TAB <event> TAB <to> TAB <writer>`, the event
# and writer being the table edge's own (the first edge of that move). A log that cannot be written never fails the writer.
# The baseline keeps today's states legal: a `<machine> TAB <state>` row allows any
# move touching that state, and a `<machine> TAB <from> TAB <event> TAB <to>` row allows that move.
#
# `flip` is the rule "turn a machine on only after a quiet period": it refuses unless the table passes its
# lint and the shadow log has no line for the machine (violation or error) newer than <seconds>, then adds
# the machine to config/machine-enforce (once). Rollback is deleting that line. The log records only
# violations, so a clean machine and a machine whose writers are not hooked yet look the same: the caller
# sets <seconds> from the day the hooks landed.
#
# Environment: JG_HOME, JG_DATA_OVERRIDE, JG_CONFIG_OVERRIDE as in other bin/ scripts; JG_MACHINES_TABLES as
# in bin/jg-machine.sh, which answers whether a move is legal (edge-check) and owns the table format.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
LOG="$DATA/machine-shadow.log"
MOVES="$DATA/machine-moves.log"
ENFORCE="$CONFIG/machine-enforce"
TABLES="${JG_MACHINES_TABLES:-$SCRIPT_DIR/../core/machines/tables}"

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
plain() { case "$1" in '' | *[!A-Za-z0-9._:@-]*) return 1 ;; esac; }
log_line() { mkdir -p "$DATA" 2>/dev/null && printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" "$4" >>"$LOG" 2>/dev/null; return 0; }

in_baseline() {  # <machine> <from> <to>
  [ -r "$TABLES/known-baseline.tsv" ] || return 1
  awk -F'\t' -v m="$1" -v f="$2" -v t="$3" \
    '$1 == m && ((NF == 2 && ($2 == f || $2 == t)) || (NF == 4 && $2 == f && $4 == t)) { hit = 1 } END { exit !hit }' \
    "$TABLES/known-baseline.tsv"
}

# move_line <machine> <id> <from> <to> <edge-check output>: one legal move onto the move log
move_line() {
  local event writer
  event=$(printf '%s\n' "$5" | awk -F'\t' '$1 ~ /^legal / { print $2; exit }')
  writer=$(printf '%s\n' "$5" | awk -F'\t' '$1 ~ /^legal / { print $3; exit }')
  mkdir -p "$DATA" 2>/dev/null && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" "$event" "$4" "$writer" >>"$MOVES" 2>/dev/null
  return 0
}

cmd_edge() {
  # a record's first move starts from the word (none), which only the from position may hold
  if [ $# -lt 3 ] || [ $# -gt 4 ] || ! plain "$1" || { [ "$2" != '(none)' ] && ! plain "$2"; } || ! plain "$3" || { [ $# -eq 4 ] && ! plain "$4"; }; then usage; fi
  local m=$1 from=$2 to=$3 id=${4:--} out rc mode=shadow
  [ "$from" = - ] && from='(none)'  # `-` is a record that does not exist yet: the table's `(none)` edges
  out=$(bash "$SCRIPT_DIR/jg-machine.sh" edge-check "$m" "$from" "$to" 2>&1); rc=$?
  [ "$rc" = 0 ] && { move_line "$m" "$id" "$from" "$to" "$out"; return 0; }
  case "$out" in
    lint\ * | *'no table'*) log_line "$m" "$from" "$to" error; echo "jg-machine-guard: $m: no usable table, move allowed" >&2; return 0 ;;
  esac
  case "$out" in illegal\ * | *'is not a state'*) ;; *) log_line "$m" "$from" "$to" error; return 0 ;; esac
  in_baseline "$m" "$from" "$to" && return 0
  grep -qxF -- "$m" "$ENFORCE" 2>/dev/null && mode=refused
  log_line "$m" "$from" "$to" "$mode"
  [ "$mode" = shadow ] && return 0
  echo "jg-machine-guard: refused $m: $from -> $to is not a legal move; run: bin/jg-machine.sh next $m <id>" >&2
  return 1
}

cmd_flip() {
  if [ $# -ne 2 ] || ! plain "$1"; then usage; fi
  case "$2" in '' | *[!0-9]*) usage ;; esac
  local m=$1 secs=$2 last now
  bash "$SCRIPT_DIR/jg-machine.sh" check "$m" >/dev/null 2>&1 || { echo "jg-machine-guard: $m has no table that passes its lint" >&2; return 1; }
  now=$(date +%s)
  last=$(awk -F'\t' -v m="$m" '$2 == m && $1 + 0 > e { e = $1 + 0 } END { print e + 0 }' "$LOG" 2>/dev/null)
  if [ $((now - ${last:-0})) -lt "$secs" ]; then
    echo "jg-machine-guard: $m is not quiet: its newest shadow line is $((now - last))s old, the period is ${secs}s" >&2
    return 1
  fi
  grep -qxF -- "$m" "$ENFORCE" 2>/dev/null && return 0
  mkdir -p "$CONFIG" && printf '%s\n' "$m" >>"$ENFORCE"
}

cmd_enforced() {
  if [ $# -ne 1 ] || ! plain "$1"; then usage; fi
  grep -qxF -- "$1" "$ENFORCE" 2>/dev/null
}

case "${1:-}" in
  enforced) shift; cmd_enforced "$@" ;;
  edge) shift; cmd_edge "$@" ;;
  flip) shift; cmd_flip "$@" ;;
  *) usage ;;
esac
