#!/usr/bin/env bash
# jg-backlog-spawnable.sh - the tickets this home can start now.
#
# Usage: jg-backlog-spawnable.sh [--with-filer]   (bin/jg-backlog.sh `ready --spawnable` runs it)
#
# Prints `count: <n>`, then one `<id>\t<project>` line per ticket. A ticket can
# start when the store lists it ready and all of these hold:
#   - it is work, not a decision card, and nobody holds it (no assignee, no hold record);
#   - it names a project that data/projects.md registers for this home;
#   - no live lane holds it (no state/<id>.meta);
#   - no open captain decision card is linked to it, in either direction.
# The ticket tables in fleet.db answer it (core/item-store/adapters/tickets.py spawnable): one
# `<id>\t<project:label>` line per startable row and project label, in the order `bd ready` used:
# priority, then age. The project and live-lane checks run here on that small answer.
# --with-filer includes the stored filing actor as a third tab-separated column.
# The caller bounds the whole run (bin/jg-backlog.sh gives it 10 seconds).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"

die() { printf 'jg-backlog-spawnable: %s\n' "$1" >&2; exit "${2:-2}"; }

tmp=$(mktemp -d) || die "no scratch directory"
trap 'rm -rf -- "$tmp"' EXIT
# Registered project names: the text between "- " and the first " [" or " - ".
sed -n 's/^- \(.*\)$/\1/p' "$DATA/projects.md" 2>/dev/null \
  | sed -e 's/ \[.*$//' -e 's/ - .*$//' > "$tmp/projects"
for f in "$STATE"/*.meta; do [ -e "$f" ] && basename "$f" .meta; done > "$tmp/lanes"

JG_HOME="$JG_HOME" python3 "$SCRIPT_DIR/../core/item-store/adapters/tickets.py" spawnable "$@" > "$tmp/rows" 2>"$tmp/err" \
  || die "the tables read failed: $(cat "$tmp/err" "$tmp/rows" | head -c 300)"   # tickets.py names a fault on stdout

# Each row comes out once per project label: keep the first registered project of a row no live lane holds.
list=$(awk -F'\t' -v lanes="$tmp/lanes" -v projects="$tmp/projects" -v filer="${1:-}" '
  BEGIN { while ((getline l < lanes) > 0) lane[l] = 1; while ((getline p < projects) > 0) reg[p] = 1 }
  { id = $1; label = $2; sub(/^project:/, "", label)
    if (!(label in reg) || (id in lane) || (id in done)) next
    done[id] = 1; printf "%s\t%s%s\n", id, label, (filer == "--with-filer" ? "\t" $3 : "") }' "$tmp/rows")
count=0
[ -z "$list" ] || count=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
printf 'count: %s\n' "$count"
[ -z "$list" ] || printf '%s\n' "$list"
