#!/usr/bin/env bash
# Remove the item-store-lanes watcher check. Usage: lanes-unwiring.sh [--dry-run] <jg-home>
# The store and the cursors stay: nothing reads them. Remove config/item-store separately to stop the guarded reads.
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'usage: lanes-unwiring.sh [--dry-run] <jg-home>' >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
f=$FMH/state/item-store-lanes.check.sh
if [ -e "$f" ]; then
  [ -x "$FMH/bin/jg-check-unregister.sh" ] || { echo "remove manually: $f" >&2; exit 1; }
  if [ "$DRY" -eq 1 ]; then echo "would run: $FMH/bin/jg-check-unregister.sh item-store-lanes"; else env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-unregister.sh" item-store-lanes; fi
else
  echo "item-store-lanes: not wired in $FMH"
fi
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
