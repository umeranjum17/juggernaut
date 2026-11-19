#!/usr/bin/env bash
# Remove the item-store-sweep watcher check. Usage: unwiring-sweep.sh [--dry-run] <jg-home>
# Items already written stay in fleet.db.
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'usage: unwiring-sweep.sh [--dry-run] <jg-home>' >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
f=$FMH/state/item-store-sweep.check.sh
if [ -e "$f" ]; then
  [ -x "$FMH/bin/jg-check-unregister.sh" ] || { echo "remove manually: $f" >&2; exit 1; }
  if [ "$DRY" -eq 1 ]; then echo "would run: $FMH/bin/jg-check-unregister.sh item-store-sweep"; else env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-unregister.sh" item-store-sweep; fi
else
  echo "item-store: the sweep is not wired in $FMH"
fi
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
