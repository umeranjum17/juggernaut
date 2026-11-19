#!/usr/bin/env bash
# Remove the item-store-chat watcher check. Usage: chat-unwiring.sh [--dry-run] <jg-home>
# The would-send log and the cursors stay. Remove config/chat-store separately: with it absent the bridge does nothing.
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'usage: chat-unwiring.sh [--dry-run] <jg-home>' >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
f=$FMH/state/item-store-chat.check.sh
if [ -e "$f" ]; then
  [ -x "$FMH/bin/jg-check-unregister.sh" ] || { echo "remove manually: $f" >&2; exit 1; }
  if [ "$DRY" -eq 1 ]; then echo "would run: $FMH/bin/jg-check-unregister.sh item-store-chat"; else env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-unregister.sh" item-store-chat; fi
else
  echo "item-store-chat: not wired in $FMH"
fi
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
