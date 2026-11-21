#!/usr/bin/env bash
# Register the Main-down watcher check in a Squad Lead home. Idempotent. Usage: supervision-wiring.sh [--dry-run] <lead home>
# The check runs `supervision.py check <home>` only while the main home has config/item-store. The main home cannot watch
# itself (its own watcher stopping is what the check reads), so it is refused with exit 2. Rollback: supervision-unwiring.sh.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-register.sh" ] || { echo "usage: supervision-wiring.sh [--dry-run] <lead home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
[ -e "$FMH/.jg-squad-lead-home" ] || { echo "item-store: the main home cannot watch itself: $FMH is not a Squad Lead home" >&2; exit 2; }
ID=item-store-supervision
SHIM=$FMH/state/$ID.check.sh
refuse() { printf 'item-store: refused: %s\n' "$*" >&2; exit 1; }
ADAPTER=$FMH/core/item-store/adapters/supervision.py
MAIN=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import itemdb; print(itemdb.main_home(sys.argv[2]))' "$FMH/core/item-store" "$FMH") \
  || refuse "the home's parent binding names no main home"
SHIM_TEXT=$(printf '#!/usr/bin/env bash\n[ -e %q ] || exit 0\nexec env JG_HOME=%q python3 -I %q check %q\n' "$MAIN/config/item-store" "$FMH" "$ADAPTER" "$FMH")

if [ "$DRY" -eq 1 ]; then
  echo "would write: $SHIM:"
  printf '%s\n' "$SHIM_TEXT" | sed 's/^/  /'
  echo "would run: env -u JG_STATE_OVERRIDE JG_HOME=$FMH $FMH/bin/jg-check-register.sh $ID"
  echo "dry run: nothing written"
  exit 0
fi
[ -f "$ADAPTER" ] || refuse "$ADAPTER is missing"
if [ ! -d "$FMH/state" ] || [ -L "$FMH/state" ]; then refuse "the home has no state directory at $FMH/state"; fi
if [ -L "$SHIM" ] || { [ -e "$SHIM" ] && [ ! -f "$SHIM" ]; }; then refuse "$SHIM is not a regular file; move it aside and run this again"; fi
backup=''
if [ -f "$SHIM" ]; then
  backup=$(mktemp "$FMH/state/.jg-item-store-sup-install.XXXXXX") || refuse "cannot write in $FMH/state"
  cp -p "$SHIM" "$backup"
fi
trap '[ -z "$backup" ] || rm -f -- "$backup"' EXIT
printf '%s\n' "$SHIM_TEXT" > "$SHIM"
chmod 700 "$SHIM"
if ! env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" "$ID"; then
  if [ -n "$backup" ]; then cp -p "$backup" "$SHIM"; else rm -f -- "$SHIM"; fi
  refuse "the check could not be registered; the home's previous wiring is back"
fi
echo "item-store: wired the Main-down check in $FMH (runs only while $MAIN/config/item-store exists)"
