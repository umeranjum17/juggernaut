#!/usr/bin/env bash
# Arm the temp-directory reaper in one juggernaut home: bin/jg-tmp-reaper.sh arm writes the home's
# state/tmp-reaper.check.sh and registers it, so jg-* scratch cannot fill the temp directory. Idempotent.
# Usage: wiring.sh [--dry-run] <jg-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-tmp-reaper.sh" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
if [ "$DRY" -eq 1 ]; then
  echo "would run: env -u JG_STATE_OVERRIDE JG_HOME=$FMH $FMH/bin/jg-tmp-reaper.sh arm"
  exit 0
fi
env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-tmp-reaper.sh" arm
