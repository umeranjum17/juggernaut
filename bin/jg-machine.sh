#!/usr/bin/env bash
# jg-machine.sh - ask one command for a record's state and its legal moves, from a machine table.
#
# Usage:
#   jg-machine.sh show <machine> <id>                 the state, its kind, its captain sentence, its required fields
#   jg-machine.sh next <machine> <id>                 the state and each legal move: event, to, writer, command, guard
#   jg-machine.sh check <machine> [--corpus <file>]   lint the table; with a corpus, replay it against the table
#   jg-machine.sh events <machine>                    the events the table declares: event, from, to
#   jg-machine.sh word <map> <list> <word>            where a word of an older list lands: target, wait, health
#   jg-machine.sh replay <map> <corpus>               every `list<TAB>word` line of the corpus must have a target
#   jg-machine.sh records <map> <records>             each pull request record must get the target its line names
#
# A machine is one TSV table, <machine>.tsv, in core/machines/tables (override: JG_MACHINES_TABLES).
# core/machines/README.md owns the table format, the lint rules, the output and the exit codes.
# The command only reads: it runs the table's observer, never a move's command.
# Exit 0 is success, 1 a finding (a table defect, a record in no state, a corpus line the table lacks), 2 a usage error.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
JG_MACHINES_TABLES=${JG_MACHINES_TABLES:-$root/core/machines/tables}
export JG_MACHINES_TABLES
case "${1:-}" in
  word|replay|records) exec python3 -I -B "$root/core/machines/bin/wordmap.py" "$@" ;;
  *) exec python3 -I -B "$root/core/machines/bin/machine.py" "$@" ;;
esac
