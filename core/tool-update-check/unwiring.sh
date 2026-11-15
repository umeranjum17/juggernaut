#!/usr/bin/env bash
# Disarm the tool-update-check watcher check in one juggernaut home. Usage: unwiring.sh [--dry-run] <jg-home>
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'usage: unwiring.sh [--dry-run] <jg-home>' >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../bin" && pwd -P)
if [ "$DRY" -eq 1 ]; then
  echo "would run: JG_HOME=$FMH $BIN/jg-tool-update-check.sh disarm"
  echo "dry run: nothing written"
  exit 0
fi
JG_HOME="$FMH" "$BIN/jg-tool-update-check.sh" disarm
