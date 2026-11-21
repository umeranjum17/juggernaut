#!/usr/bin/env bash
# Register the item-store watcher check in this home. Run it in every home of the host: each home's watcher runs the
# tick, and the tick's lease lets one of them run per cycle, so the climbs go on when Main's watcher stops. Idempotent.
# Usage: wiring.sh [--dry-run] <jg-home>
# The check runs `jg-item tick` from the home's own core/item-store, and only when the home has config/item-store.
# With that file absent the check prints nothing and does nothing, so the install is safe to leave in place.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-register.sh" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
ID=item-store
SHIM=$FMH/state/$ID.check.sh
refuse() { printf 'item-store: refused: %s\n' "$*" >&2; exit 1; }
SHIM_TEXT=$(printf '#!/usr/bin/env bash\n[ -e %q ] || exit 0\nexec env JG_HOME=%q %q tick\n' "$FMH/config/item-store" "$FMH" "$FMH/core/item-store/jg-item")

if [ "$DRY" -eq 1 ]; then
  echo "would write: $SHIM:"
  printf '%s\n' "$SHIM_TEXT" | sed 's/^/  /'
  echo "would run: env -u JG_STATE_OVERRIDE JG_HOME=$FMH $FMH/bin/jg-check-register.sh $ID"
  echo "dry run: nothing written"
  exit 0
fi
[ -x "$FMH/core/item-store/jg-item" ] || refuse "$FMH/core/item-store/jg-item is missing or not executable"
if [ ! -d "$FMH/state" ] || [ -L "$FMH/state" ]; then refuse "the home has no state directory at $FMH/state"; fi
if [ -L "$SHIM" ] || { [ -e "$SHIM" ] && [ ! -f "$SHIM" ]; }; then refuse "$SHIM is not a regular file; move it aside and run this again"; fi
backup=''
if [ -f "$SHIM" ]; then
  backup=$(mktemp "$FMH/state/.jg-item-store-install.XXXXXX") || refuse "cannot write in $FMH/state"
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
