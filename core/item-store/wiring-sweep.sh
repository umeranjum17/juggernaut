#!/usr/bin/env bash
# Register the item-store-sweep watcher check in this home: cleanup.py sweep returns each finished lane's copy through the guarded cleanup and closes each update item once its home runs the release. Idempotent.
# Usage: wiring-sweep.sh [--dry-run] <jg-home>
# The check runs `cleanup.py sweep` and only when the home has config/item-store.
# With that file absent the check prints nothing and does nothing, so the install is safe to leave in place.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-register.sh" ] || { echo "usage: wiring-sweep.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
ID=item-store-sweep
SHIM=$FMH/state/$ID.check.sh
refuse() { printf 'item-store: refused: %s\n' "$*" >&2; exit 1; }
SHIM_TEXT=$(printf '#!/usr/bin/env bash\n[ -e %q ] || exit 0\nexec env JG_HOME=%q python3 -I %q sweep\n' "$FMH/config/item-store" "$FMH" "$FMH/core/item-store/adapters/cleanup.py")

if [ "$DRY" -eq 1 ]; then
  echo "would write: $SHIM:"
  printf '%s\n' "$SHIM_TEXT" | sed 's/^/  /'
  echo "would run: env -u JG_STATE_OVERRIDE JG_HOME=$FMH $FMH/bin/jg-check-register.sh $ID"
  echo "dry run: nothing written"
  exit 0
fi
[ -f "$FMH/core/item-store/adapters/cleanup.py" ] || refuse "$FMH/core/item-store/adapters/cleanup.py is missing"
if [ ! -d "$FMH/state" ] || [ -L "$FMH/state" ]; then refuse "the home has no state directory at $FMH/state"; fi
if [ -L "$SHIM" ] || { [ -e "$SHIM" ] && [ ! -f "$SHIM" ]; }; then refuse "$SHIM is not a regular file; move it aside and run this again"; fi
backup=''
if [ -f "$SHIM" ]; then
  backup=$(mktemp "$FMH/state/.jg-item-store-sweep-install.XXXXXX") || refuse "cannot write in $FMH/state"
  cp -p "$SHIM" "$backup"
fi
trap '[ -z "$backup" ] || rm -f -- "$backup"' EXIT
printf '%s\n' "$SHIM_TEXT" > "$SHIM"
chmod 700 "$SHIM"
if ! env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" "$ID"; then
  if [ -n "$backup" ]; then cp -p "$backup" "$SHIM"; else rm -f -- "$SHIM"; fi
  refuse "the check could not be registered; the home's previous wiring is back"
fi
echo "item-store: wired $FMH (runs only while $FMH/config/item-store exists)"
