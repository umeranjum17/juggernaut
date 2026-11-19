#!/usr/bin/env bash
# STUB (slice 8b1): no guard; it only records the move for the log's readers (core/fleet-status, core/lead-sweep).
# jg-move.sh - record one ticket move: append one line to data/moves.log.
#
# Usage: jg-move.sh [--shadow] <ticket> <event>
#
# Every well-formed call appends one line to data/moves.log and exits 0; nothing is checked or refused:
#   <epoch> TAB <ticket> TAB <from> TAB <event> TAB <to>
# <from> and <to> come from the table's observer when it can place the ticket and the event is one of its moves,
# else `(none)` and `-`. --shadow is accepted and changes nothing. Exit 2 is a usage error.
# Env: JG_HOME, JG_DATA_OVERRIDE, JG_MACHINES_TABLES as in bin/jg-machine.sh.
set -u
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JG_HOME=${JG_HOME:-$(cd "$here/.." && pwd)}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
JM=$here/jg-machine.sh
plain() { case "$1" in '' | *[!A-Za-z0-9._:@-]*) return 1 ;; esac; }
usage() { sed -n '5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
if [ "${1-}" = --shadow ]; then shift; fi
if [ "$#" -ne 2 ] || ! plain "$1" || ! plain "$2"; then usage; fi
ticket=$1 event=$2
from='(none)' to=-
if out=$(bash "$JM" next ticket "$ticket" 2>/dev/null); then
  from=$(printf '%s\n' "$out" | sed -n 's/^state\t//p')
  to=$(printf '%s\n' "$out" | awk -F'\t' -v e="$event" '$1 == "move" && $2 == e { print $3; exit }')
  : "${to:=-}"
fi
if ! { mkdir -p "$DATA" && printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$ticket" "$from" "$event" "$to" >>"$DATA/moves.log"; }; then
  echo "jg-move: cannot write $DATA/moves.log" >&2; exit 1
fi
