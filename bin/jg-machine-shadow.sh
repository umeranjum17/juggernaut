#!/usr/bin/env bash
# jg-machine-shadow.sh - a writer reports the move it is about to make to the machine table, in shadow.
#
# Usage: jg-machine-shadow.sh <machine> <id> <to>
#
# Reads the record's state now with `bin/jg-machine.sh show` (the table's observer), then hands the move
# <state> -> <to> to bin/jg-machine-guard.sh edge, which owns the verdict, the baseline and the log line
# (data/machine-shadow.log, one line per illegal move; a legal move goes to data/machine-moves.log, the one move
# log of every machine, with its time, machine, id, from, event, to and writer).
# The writer carries on either way: this command never refuses, never changes a record, and always exits 0,
# even for a machine listed in config/machine-enforce, because enforcement is a later, per-machine step.
# A missing engine, guard or table, an id the observer cannot place, or a read past the bound is a silent no-op.
# Env: JG_HOME (default: the home this script sits in), JG_DATA_OVERRIDE, JG_MACHINES_TABLES, JG_SHADOW_BOUND seconds (default 5).
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ "$#" -eq 3 ] && [ -x "$here/jg-machine.sh" ] && [ -x "$here/jg-machine-guard.sh" ] && [ -r "$here/jg-timeout-lib.sh" ] || exit 0
# shellcheck source=bin/jg-timeout-lib.sh
. "$here/jg-timeout-lib.sh"
export JG_HOME=${JG_HOME:-$(cd "$here/.." && pwd)}
bound=${JG_SHADOW_BOUND:-5}
from=$(jg_run_timed "$bound" "$here/jg-machine.sh" show "$1" "$2" 2>/dev/null | sed -n 's/^state\t//p')
[ -n "$from" ] && jg_run_timed "$bound" "$here/jg-machine-guard.sh" edge "$1" "$from" "$3" "$2" >/dev/null 2>&1
exit 0
