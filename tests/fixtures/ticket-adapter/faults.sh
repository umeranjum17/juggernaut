#!/usr/bin/env bash
# The faults driver the conformance script calls as `faults.sh <none|unreadable|partial>`: it leaves the mode beside the
# store named by BEADS_DIR, where faulty-beads.sh reads it.
set -eu
case "${1-}" in
  none) rm -f "$(dirname "$BEADS_DIR")/.fault" ;;
  unreadable|partial) printf '%s\n' "$1" >"$(dirname "$BEADS_DIR")/.fault" ;;
  *) echo "usage: faults.sh <none|unreadable|partial>" >&2; exit 2 ;;
esac
