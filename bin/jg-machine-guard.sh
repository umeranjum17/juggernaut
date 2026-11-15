#!/usr/bin/env bash
# jg-machine-guard.sh - the one call a writer makes before it moves a record along a machine edge, and the
# per-machine flip from shadow to refusal.
#
# Usage:
#   jg-machine-guard.sh edge <machine> <from|-> <to> [<id>]   judge one move (`-`: the record is new); exit 0 allowed, exit 1 refused, exit 2 usage
#   jg-machine-guard.sh flip <machine> <seconds>     list the machine in config/machine-enforce, only when quiet
#   jg-machine-guard.sh enforced <machine>           exit 0 when the machine is listed in config/machine-enforce, else 1
#   jg-machine-guard.sh fact <name> [args]           print one typed fact as `key TAB value` lines, changing nothing: policy <machine> <from> <to>,
#                                                    reuse, writer <ref> <new-sha>, ready <id>, flush <file> <ready> <oldest> <now> <at-ready> <after-min>,
#                                                    retry <id> <now> <start-s>, wake <file> (readers: bin/jg-facts-lib.sh)
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

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
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

# judge <machine> <from> <to>: the one reading of a move. Sets J_VERDICT (legal | baseline | illegal | error), J_MODE (shadow | enforced),
# J_BASELINE (yes | no), J_TABLE (usable | unusable), J_OUTCOME (allowed | refused) and J_OUT (the edge-check text). It writes nothing.
judge() {
  local rc=0
  J_MODE=shadow J_BASELINE=no J_TABLE=usable
  grep -qxF -- "$1" "$ENFORCE" 2>/dev/null && J_MODE=enforced
  in_baseline "$1" "$2" "$3" && J_BASELINE=yes
  J_OUT=$(bash "$SCRIPT_DIR/jg-machine.sh" edge-check "$1" "$2" "$3" 2>&1) || rc=$?
  J_OUTCOME=allowed
  if [ "$rc" = 0 ]; then J_VERDICT=legal; return 0; fi
  case "$J_OUT" in
    lint\ * | *'no table'*) J_VERDICT=error J_TABLE=unusable; return 0 ;;
  esac
  case "$J_OUT" in illegal\ * | *'is not a state'*) ;; *) J_VERDICT=error; return 0 ;; esac
  if [ "$J_BASELINE" = yes ]; then J_VERDICT=baseline; return 0; fi
  J_VERDICT=illegal
  [ "$J_MODE" = enforced ] && J_OUTCOME=refused
  return 0
}

cmd_edge() {
  # a record's first move starts from the word (none), which only the from position may hold
  if [ $# -lt 3 ] || [ $# -gt 4 ] || ! plain "$1" || { [ "$2" != '(none)' ] && ! plain "$2"; } || ! plain "$3" || { [ $# -eq 4 ] && ! plain "$4"; }; then usage; fi
  local m=$1 from=$2 to=$3 id=${4:--}
  [ "$from" = - ] && from='(none)'  # `-` is a record that does not exist yet: the table's `(none)` edges
  judge "$m" "$from" "$to"
  case $J_VERDICT in
    legal) move_line "$m" "$id" "$from" "$to" "$J_OUT"; return 0 ;;
    baseline) return 0 ;;
    error)
      log_line "$m" "$from" "$to" error
      [ "$J_TABLE" = usable ] || echo "jg-machine-guard: $m: no usable table, move allowed" >&2
      return 0 ;;
  esac
  log_line "$m" "$from" "$to" "$([ "$J_OUTCOME" = refused ] && echo refused || echo shadow)"
  [ "$J_OUTCOME" = allowed ] && return 0
  echo "jg-machine-guard: refused $m: $from -> $to is not a legal move; run: bin/jg-machine.sh next $m <id>" >&2
  return 1
}

# fact <name> [args]: print one typed fact (bin/jg-facts-lib.sh owns the readers); nothing is logged or changed.
cmd_fact() {
  local name=${1:-} state="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
  [ $# -ge 1 ] || usage; shift
  # shellcheck source=bin/jg-facts-lib.sh
  . "$SCRIPT_DIR/jg-facts-lib.sh"
  case $name in
    policy)
      if [ $# -ne 3 ] || ! plain "$1" || { [ "$2" != '(none)' ] && ! plain "$2"; } || ! plain "$3"; then usage; fi
      [ "$2" != - ] || set -- "$1" '(none)' "$3"
      judge "$1" "$2" "$3"
      printf 'machine\t%s\nmode\t%s\nmode_source\t%s\nbaseline\t%s\ntable\t%s\nverdict\t%s\noutcome\t%s\n' \
        "$1" "$J_MODE" "$ENFORCE" "$J_BASELINE" "$J_TABLE" "$J_VERDICT" "$J_OUTCOME" ;;
    reuse) [ $# -eq 0 ] || usage; jg_fact_reuse ;;
    writer) [ $# -eq 2 ] || usage; jg_fact_writer "$1" "$2" ;;
    ready) { [ $# -eq 1 ] && plain "$1"; } || usage; jg_fact_ready "$state" "$1" ;;
    flush) [ $# -eq 6 ] || usage; jg_fact_flush "$@" ;;
    retry) { [ $# -eq 3 ] && plain "$1"; } || usage; jg_fact_sweep_retry "$state" "${JG_DATA_OVERRIDE:-$JG_HOME/data}/lead-sweep" "$1" "$2" "$3" ;;
    wake) [ $# -eq 1 ] || usage
      # shellcheck source=bin/jg-wake-lib.sh
      . "$SCRIPT_DIR/jg-wake-lib.sh"; jg_fact_wake "$state" "$1" ;;
    *) usage ;;
  esac
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
  fact) shift; cmd_fact "$@" ;;
  flip) shift; cmd_flip "$@" ;;
  *) usage ;;
esac
