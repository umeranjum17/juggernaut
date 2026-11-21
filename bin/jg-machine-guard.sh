#!/usr/bin/env bash
# STUB (slice 8b1): no guard; `edge`, `flip` and `enforced` exit as below and record nothing; `fact` still prints its facts.
# jg-machine-guard.sh - the one call a writer makes before it moves a record along a machine edge, and the
# per-machine flip from shadow to refusal.
#
# Usage:
#   jg-machine-guard.sh edge <machine> <from|-> <to> [<id>]   stub: exit 0 for a well-formed call, exit 2 usage
#   jg-machine-guard.sh flip <machine> <seconds>     stub: exit 0, writes nothing
#   jg-machine-guard.sh enforced <machine>           stub: exit 1 (no machine is enforced)
#   jg-machine-guard.sh fact <name> [args]           print one typed fact as `key TAB value` lines, changing nothing: policy <machine> <from> <to>,
#                                                    reuse, writer <ref> <new-sha>, ready <id>, flush <file> <ready> <oldest> <now> <at-ready> <after-min>,
#                                                    retry <id> <now> <start-s>, wake <file>, next-step <id> (readers: bin/jg-facts-lib.sh)
#
# `edge` allows every move and writes nothing; `flip` writes nothing; `enforced` exits 1 for every machine. Only `fact` still reads.
#
# Environment: JG_HOME, JG_DATA_OVERRIDE, JG_CONFIG_OVERRIDE as in other bin/ scripts; JG_MACHINES_TABLES as
# in bin/jg-machine.sh, which answers whether a move is legal (edge-check) and owns the table format.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
ENFORCE="$CONFIG/machine-enforce"
TABLES="${JG_MACHINES_TABLES:-$SCRIPT_DIR/../core/machines/tables}"

usage() { sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
plain() { case "$1" in '' | *[!A-Za-z0-9._:@-]*) return 1 ;; esac; }

in_baseline() {  # <machine> <from> <to>
  [ -r "$TABLES/known-baseline.tsv" ] || return 1
  awk -F'\t' -v m="$1" -v f="$2" -v t="$3" \
    '$1 == m && ((NF == 2 && ($2 == f || $2 == t)) || (NF == 4 && $2 == f && $4 == t)) { hit = 1 } END { exit !hit }' \
    "$TABLES/known-baseline.tsv"
}

# judge <machine> <from> <to>: the one reading of a move. Sets J_VERDICT (legal | baseline | illegal | error), J_MODE (shadow | enforced),
# J_BASELINE (yes | no), J_TABLE (usable | unusable), J_OUTCOME (allowed | refused) and J_OUT (the edge-check text). It writes nothing.
judge() {
  local rc=0
  J_MODE=shadow J_BASELINE=no J_TABLE=usable
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
  return 0
}

# edge: a stub. It checks the usage, allows every move and writes no log line.
cmd_edge() {
  if [ $# -lt 3 ] || [ $# -gt 4 ] || ! plain "$1" || { [ "$2" != '(none)' ] && ! plain "$2"; } || ! plain "$3" || { [ $# -eq 4 ] && ! plain "$4"; }; then usage; fi
  return 0
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
    next-step) { [ $# -eq 1 ] && plain "$1"; } || usage; jg_fact_next_step "$state" "${JG_DATA_OVERRIDE:-$JG_HOME/data}" "$1" ;;
    wake) [ $# -eq 1 ] || usage
      # shellcheck source=bin/jg-wake-lib.sh
      . "$SCRIPT_DIR/jg-wake-lib.sh"; jg_fact_wake "$state" "$1" ;;
    *) usage ;;
  esac
}

# flip: a stub. Nothing is enforced any more, so there is nothing to list.
cmd_flip() {
  if [ $# -ne 2 ] || ! plain "$1"; then usage; fi
  return 0
}

# enforced: a stub. No machine is enforced.
cmd_enforced() {
  if [ $# -ne 1 ] || ! plain "$1"; then usage; fi
  return 1
}

case "${1:-}" in
  enforced) shift; cmd_enforced "$@" ;;
  edge) shift; cmd_edge "$@" ;;
  fact) shift; cmd_fact "$@" ;;
  flip) shift; cmd_flip "$@" ;;
  *) usage ;;
esac
