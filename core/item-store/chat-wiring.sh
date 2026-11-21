#!/usr/bin/env bash
# Register the item-store-chat watcher check in the MAIN home. Idempotent.
# Usage: chat-wiring.sh [--dry-run] <main-home>
# The check runs the chat bridge's `would-send` then `compare` (adapters/chat_bridge.py) from the home's own core/item-store, and only
# while the home has config/chat-store; it prints nothing and never fails. The bridge sends nothing: the bus still sends, and the
# bridge records what it would send and compares it with the captain channel's own record. With that file absent the check does
# nothing, so the install is safe to leave in place. Rollback: remove config/chat-store, and run chat-unwiring.sh.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-register.sh" ] || { echo "usage: chat-wiring.sh [--dry-run] <main-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
ID=item-store-chat
SHIM=$FMH/state/$ID.check.sh
BRIDGE=$FMH/core/item-store/adapters/chat_bridge.py
refuse() { printf 'item-store-chat: refused: %s\n' "$*" >&2; exit 1; }
SHIM_TEXT=$(printf '#!/usr/bin/env bash\n[ -e %q ] || exit 0\nexport JG_HOME=%q\npython3 -I %q would-send >/dev/null 2>&1\npython3 -I %q compare >/dev/null 2>&1\nexit 0\n' \
  "$FMH/config/chat-store" "$FMH" "$BRIDGE" "$BRIDGE")

if [ "$DRY" -eq 1 ]; then
  echo "would write: $SHIM:"
  printf '%s\n' "$SHIM_TEXT" | sed 's/^/  /'
  echo "would run: env -u JG_STATE_OVERRIDE JG_HOME=$FMH $FMH/bin/jg-check-register.sh $ID"
  echo "dry run: nothing written"
  exit 0
fi
[ -f "$BRIDGE" ] || refuse "$BRIDGE is missing"
[ ! -e "$FMH/.jg-squad-lead-home" ] || refuse "$FMH is a Squad Lead home: the chat bridge runs in the main home only"
if [ ! -d "$FMH/state" ] || [ -L "$FMH/state" ]; then refuse "the home has no state directory at $FMH/state"; fi
if [ -L "$SHIM" ] || { [ -e "$SHIM" ] && [ ! -f "$SHIM" ]; }; then refuse "$SHIM is not a regular file; move it aside and run this again"; fi
backup=''
if [ -f "$SHIM" ]; then
  backup=$(mktemp "$FMH/state/.jg-item-store-chat-install.XXXXXX") || refuse "cannot write in $FMH/state"
  cp -p "$SHIM" "$backup"
fi
trap '[ -z "$backup" ] || rm -f -- "$backup"' EXIT
printf '%s\n' "$SHIM_TEXT" > "$SHIM"
chmod 700 "$SHIM"
if ! env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" "$ID"; then
  if [ -n "$backup" ]; then cp -p "$backup" "$SHIM"; else rm -f -- "$SHIM"; fi
  refuse "the check could not be registered; the home's previous wiring is back"
fi
echo "item-store-chat: wired $FMH (runs only while $FMH/config/chat-store exists)"
