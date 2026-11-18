#!/usr/bin/env bash
# Remove the Main-down watcher check from a Squad Lead home. Usage: supervision-unwiring.sh [--dry-run] <lead home>
# Items already written stay in fleet.db.
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'usage: supervision-unwiring.sh [--dry-run] <lead home>' >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
f=$FMH/state/item-store-supervision.check.sh
if [ -e "$f" ]; then
  [ -x "$FMH/bin/jg-check-unregister.sh" ] || { echo "remove manually: $f" >&2; exit 1; }
  if [ "$DRY" -eq 1 ]; then echo "would run: $FMH/bin/jg-check-unregister.sh item-store-supervision"; else env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-unregister.sh" item-store-supervision; fi
else
  echo "item-store: the Main-down check is not wired in $FMH"
fi
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
