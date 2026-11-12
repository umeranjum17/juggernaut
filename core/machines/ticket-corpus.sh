#!/usr/bin/env bash
# ticket-corpus.sh - every word the ticket map must cover, as `list<TAB>word` lines for `jg-machine.sh replay ticket-words`.
#
# Usage: ticket-corpus.sh [--tables <dir>] [--state <dir>] [--shadow <file>]
#
# The lists: each state of every older machine table (list: the table's name); the leading verb of every line of every
# state/*.status log (list: status-verb); and both words of every line of the shadow log (list: the machine's name).
# Defaults: this repository's tables, <home>/state and <home>/data/machine-shadow.log. It only reads.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
home=${JG_HOME:-$root}
tables=$root/core/machines/tables; state=${JG_STATE_OVERRIDE:-$home/state}; shadow=${JG_DATA_OVERRIDE:-$home/data}/machine-shadow.log
while [ $# -gt 0 ]; do
  case $1 in
    --tables) tables=${2:?}; shift 2 ;;
    --state) state=${2:?}; shift 2 ;;
    --shadow) shadow=${2:?}; shift 2 ;;
    *) echo "usage: ticket-corpus.sh [--tables <dir>] [--state <dir>] [--shadow <file>]" >&2; exit 2 ;;
  esac
done
for f in "$tables"/*.tsv; do  # the new tables of the ticket are the target, not a list to map
  m=$(basename "$f" .tsv); case $m in ticket|delivering|proving|release|known-baseline) continue ;; esac
  awk -F'\t' -v m="$m" '$1 == "state" { print m "\t" $2 }' "$f"
done | grep -Ev '^(message|worker|bypass|presence|squad-lead|supervision|alert)'$'\t'  # the message, worker, bypass, presence, squad-lead, supervision and alert tables are new tables of the ticket plan, a target and not an older list
for f in "$state"/*.status; do
  [ -e "$f" ] && sed -E '/^$/d; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z //; s/^([^ :[]+).*/status-verb\t\1/' "$f"
done
[ -e "$shadow" ] && awk -F'\t' 'NF >= 4 { print $2 "\t" $3; print $2 "\t" $4 }' "$shadow"
exit 0
