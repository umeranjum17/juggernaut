#!/usr/bin/env bash
# Remove the wake-rollup registered check and installed command. Usage: unwiring.sh [--dry-run] <jg-home>
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'usage: unwiring.sh [--dry-run] <jg-home>' >&2; exit 2; }
FMH=$(cd "$1" && pwd -P); DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-wake-rollup; f=$FMH/state/wake-rollup.check.sh
if [ -e "$f" ]; then
  [ -x "$FMH/bin/jg-check-unregister.sh" ] || { echo "remove manually: $f" >&2; exit 1; }
  if [ "$DRY" -eq 1 ]; then echo "would run: $FMH/bin/jg-check-unregister.sh wake-rollup"; else env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-unregister.sh" wake-rollup; fi
fi
[ ! -e "$DEST/rollup.sh" ] || { echo "remove: $DEST/rollup.sh"; [ "$DRY" -eq 1 ] || rm -f -- "$DEST/rollup.sh"; }
[ "$DRY" -eq 1 ] || rmdir "$DEST" 2>/dev/null || true
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
