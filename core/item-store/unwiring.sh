#!/usr/bin/env bash
# Remove the item-store watcher check. Usage: unwiring.sh [--dry-run] <jg-home>
# fleet.db stays: nothing reads it. Remove config/item-store separately to stop the tick being wanted.
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'usage: unwiring.sh [--dry-run] <jg-home>' >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
f=$FMH/state/item-store.check.sh
if [ -e "$f" ]; then
  [ -x "$FMH/bin/jg-check-unregister.sh" ] || { echo "remove manually: $f" >&2; exit 1; }
  if [ "$DRY" -eq 1 ]; then echo "would run: $FMH/bin/jg-check-unregister.sh item-store"; else env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-unregister.sh" item-store; fi
else
  echo "item-store: not wired in $FMH"
fi
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
