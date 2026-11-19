#!/usr/bin/env bash
# jg-beads.sh - the one way the fleet makes a `bd` call; the tickets tables in fleet.db answer it.
# STUB (slice 10b2a): bd and dolt are not run; bd_compat.py answers from fleet.db. Deleted by slice 10b2f.
#
# Usage: jg-beads.sh <bd verb> [args...]   runs core/item-store/adapters/bd_compat.py with the same arguments and streams
#        jg-beads.sh check                 runs tickets.py check: the tables exist, their hash matches, no row breaks the hold rule
#        jg-beads.sh init ...              exits 0 with one line naming the tables: they are the store
#        jg-beads.sh dolt ...              exits 2 with `Beads is retired: no dolt`
#        jg-beads.sh --help
# The home is JG_HOME (the repository when unset); BEADS_DIR is not read.
set -u

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ADAPTERS="$SCRIPT_DIR/../core/item-store/adapters"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

case "${1:-}" in
  ''|-h|--help) usage; exit 0 ;;
  check) exec python3 -I "$ADAPTERS/tickets.py" check ;;
  init) echo "jg-beads: the tickets tables in fleet.db are the store; nothing to create"; exit 0 ;;
  dolt) echo "Beads is retired: no dolt" >&2; exit 2 ;;
  *) exec python3 -I "$ADAPTERS/bd_compat.py" "$@" ;;
esac
