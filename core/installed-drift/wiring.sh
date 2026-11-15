#!/usr/bin/env bash
# Arm the installed-drift watcher check in one juggernaut home. Idempotent.
# Usage: wiring.sh [--dry-run] <jg-home>
# The check shim execs the repo script, so no installed copy is created.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1/state" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../bin" && pwd -P)
if [ "$DRY" -eq 1 ]; then
  echo "would run: JG_HOME=$FMH $BIN/jg-installed-drift.sh arm"
  echo "dry run: nothing written"
  exit 0
fi
JG_HOME="$FMH" "$BIN/jg-installed-drift.sh" arm
