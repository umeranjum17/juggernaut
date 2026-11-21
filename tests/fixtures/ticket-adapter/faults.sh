#!/usr/bin/env bash
# The faults driver the conformance script calls as `faults.sh <none|unreadable|partial>`, on the tickets tables of the home JG_HOME
# names: unreadable takes every permission off its fleet.db so each read fails, none gives them back. The tables are read in one
# query, so no read of them is ever partial: partial is refused, and the conformance check that needs it fails by name.
set -eu
db=$JG_HOME/state/item-store/fleet.db
case "${1-}" in
  none) [ ! -e "$db" ] || chmod 600 "$db" ;;
  unreadable) [ -e "$db" ] || { echo "faults.sh: no tables at $db" >&2; exit 1; }; chmod 000 "$db" ;;
  partial) echo "faults.sh: the tickets tables are read in one query, so no read is partial" >&2; exit 2 ;;
  *) echo "usage: faults.sh <none|unreadable|partial>" >&2; exit 2 ;;
esac
