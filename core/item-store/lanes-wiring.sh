#!/usr/bin/env bash
# Register the item-store-lanes watcher check in this home. Run it in every home, after `lane.py import <home>`: the check is the
# net under the guarded status append (bin/jg-lavish-guard.sh reads each appended line at once), so a line written any other way
# still reaches the item store within one cycle. Idempotent.
# Usage: lanes-wiring.sh [--dry-run] <jg-home>
# The check runs `lane.py scan <home>` from the home's own core/item-store, and only while the home has config/item-store; it prints
# nothing and never fails. With that file absent it does nothing, so the install is safe to leave in place.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-register.sh" ] || { echo "usage: lanes-wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
ID=item-store-lanes
SHIM=$FMH/state/$ID.check.sh
refuse() { printf 'item-store-lanes: refused: %s\n' "$*" >&2; exit 1; }
SHIM_TEXT=$(printf '#!/usr/bin/env bash\n[ -e %q ] || exit 0\npython3 -I %q scan %q >/dev/null 2>&1\nexit 0\n' \
  "$FMH/config/item-store" "$FMH/core/item-store/adapters/lane.py" "$FMH")

if [ "$DRY" -eq 1 ]; then
  echo "would write: $SHIM:"
  printf '%s\n' "$SHIM_TEXT" | sed 's/^/  /'
  echo "would run: env -u JG_STATE_OVERRIDE JG_HOME=$FMH $FMH/bin/jg-check-register.sh $ID"
  echo "dry run: nothing written"
  exit 0
fi
[ -f "$FMH/core/item-store/adapters/lane.py" ] || refuse "$FMH/core/item-store/adapters/lane.py is missing"
if [ ! -d "$FMH/state" ] || [ -L "$FMH/state" ]; then refuse "the home has no state directory at $FMH/state"; fi
if [ -L "$SHIM" ] || { [ -e "$SHIM" ] && [ ! -f "$SHIM" ]; }; then refuse "$SHIM is not a regular file; move it aside and run this again"; fi
backup=''
if [ -f "$SHIM" ]; then
  backup=$(mktemp "$FMH/state/.jg-item-store-lanes-install.XXXXXX") || refuse "cannot write in $FMH/state"
  cp -p "$SHIM" "$backup"
fi
trap '[ -z "$backup" ] || rm -f -- "$backup"' EXIT
printf '%s\n' "$SHIM_TEXT" > "$SHIM"
chmod 700 "$SHIM"
if ! env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" "$ID"; then
  if [ -n "$backup" ]; then cp -p "$backup" "$SHIM"; else rm -f -- "$SHIM"; fi
  refuse "the check could not be registered; the home's previous wiring is back"
fi
echo "item-store-lanes: wired $FMH (runs only while $FMH/config/item-store exists)"
