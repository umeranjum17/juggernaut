#!/usr/bin/env bash
# Arm the tool-update-check watcher check in one juggernaut home, only when the owner chose tools. Idempotent.
# Usage: wiring.sh [--dry-run] <jg-home>
# The owner picks the watched tools, so config/watched-tools.json is never created here; without it this
# prints "not armed: no watched-tools registry" and exits 0.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../bin" && pwd -P)
if [ ! -f "${JG_CONFIG_OVERRIDE:-$FMH/config}/watched-tools.json" ]; then
  echo "not armed: no watched-tools registry"
  exit 0
fi
if [ "$DRY" -eq 1 ]; then
  echo "would run: JG_HOME=$FMH $BIN/jg-tool-update-check.sh arm"
  echo "dry run: nothing written"
  exit 0
fi
JG_HOME="$FMH" "$BIN/jg-tool-update-check.sh" arm
