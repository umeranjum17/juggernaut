#!/usr/bin/env bash
# Disarm the temp-directory reaper in one juggernaut home. Usage: unwiring.sh [--dry-run] <jg-home>
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-tmp-reaper.sh" ] || { echo 'usage: unwiring.sh [--dry-run] <jg-home>' >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
if [ -e "$FMH/state/records-reaper.check.sh" ]; then
  if [ "$DRY" -eq 1 ]; then echo "would disarm: records-reaper"; else env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-unregister.sh" records-reaper; fi
fi
[ -e "$FMH/state/tmp-reaper.check.sh" ] || exit 0
if [ "$DRY" -eq 1 ]; then echo "would run: $FMH/bin/jg-tmp-reaper.sh disarm"; else env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-tmp-reaper.sh" disarm; fi
