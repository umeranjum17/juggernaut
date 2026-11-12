#!/usr/bin/env bash
# jg-move.sh - move one ticket along the ticket table: check the event, then append one log line.
#
# Usage: jg-move.sh [--shadow] <ticket> <event>
#
# The ticket's state now comes from the table's observer (`bin/jg-machine.sh next ticket <ticket>`), and the event must be
# one of that state's legal moves. A legal move appends one line to data/moves.log:
#   <epoch> TAB <ticket> TAB <from> TAB <event> TAB <to>
# and exits 0. An illegal move (an event the state does not have, a ticket in no state, or an unknown event) prints
# the legal events on stderr, exits 1 and changes nothing. A ticket in no state yet accepts only the table's first event.
# The command writes no other record: the writers that call it keep their own. Exit 2 is a usage error.
# --shadow is how a writer calls it before enforcement: a legal move is logged as above; an illegal one is not refused
# but appended to data/machine-shadow.log as `<epoch> TAB ticket TAB <from> TAB <event> TAB shadow` (the guard's own
# file and shape, bin/jg-machine-guard.sh), with the legal events on stderr, and the command always exits 0 so the
# writer carries on; a ticket the observer cannot place is left alone. Without it an illegal move still exits 1.
# Env: JG_HOME, JG_DATA_OVERRIDE, JG_MACHINES_TABLES as in bin/jg-machine.sh.
set -u
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JG_HOME=${JG_HOME:-$(cd "$here/.." && pwd)}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
JM=$here/jg-machine.sh
plain() { case "$1" in '' | *[!A-Za-z0-9._:@-]*) return 1 ;; esac; }
usage() { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
shadow=0 unplaced=0
if [ "${1-}" = --shadow ]; then shadow=1; shift; fi
if [ "$#" -ne 2 ] || ! plain "$1" || ! plain "$2"; then usage; fi
ticket=$1 event=$2
# refuse <from>: an illegal move ends the command: exit 1, or in shadow one log line and exit 0
refuse() {
  [ "$shadow" -eq 1 ] || exit 1
  [ "$unplaced" -eq 0 ] || exit 0  # in shadow a ticket the observer cannot place is a silent no-op, as in bin/jg-machine-shadow.sh
  { mkdir -p "$DATA" && printf '%s\tticket\t%s\t%s\tshadow\n' "$(date +%s)" "$1" "$event" >>"$DATA/machine-shadow.log"; } 2>/dev/null
  exit 0
}

out=$(bash "$JM" next ticket "$ticket" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  from=$(printf '%s\n' "$out" | sed -n 's/^state\t//p')
  moves=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "move" { print $2 "\t" $3 }')
else  # no state yet: only the first event of the machine, from (none), is legal
  from='(none)'; unplaced=1
  moves=$(bash "$JM" events ticket 2>/dev/null | awk -F'\t' '$2 == "(none)" { print $1 "\t" $3 }')
  [ -n "$moves" ] || { printf 'jg-move: %s: %s\n' "$ticket" "${out:-no state and no table}" >&2; refuse "$from"; }
fi
to=$(printf '%s\n' "$moves" | awk -F'\t' -v e="$event" '$1 == e { print $2; exit }')
if [ -z "$to" ]; then
  printf 'jg-move: refused: %s has no move "%s" from %s; legal: %s\n' "$ticket" "$event" "$from" \
    "$(printf '%s\n' "$moves" | cut -f1 | paste -sd' ' -)" >&2
  refuse "$from"
fi
# the destination is a state word: it goes through the enum reader before anything is written
bash "$here/jg-machine.sh" legal ticket "${to%%.*}" >/dev/null || refuse "$from"
if ! { mkdir -p "$DATA" && printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$ticket" "$from" "$event" "$to" >>"$DATA/moves.log"; }; then
  echo "jg-move: cannot write $DATA/moves.log" >&2; [ "$shadow" -eq 1 ] && exit 0; exit 1
fi
