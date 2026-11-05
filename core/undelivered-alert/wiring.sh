#!/usr/bin/env bash
# Install the undelivered-alert watcher check in one juggernaut home. Idempotent.
# Usage: wiring.sh [--dry-run] <jg-home>
# Same shape as core/merge-on-green/wiring.sh: copy the script to the install share, write the home's
# check shim, register it. A registration the register script refuses puts the previous shim back.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-register.sh" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ID=undelivered-alert
STATE=$FMH/state
SHIM=$STATE/$ID.check.sh
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-$ID
refuse() { printf 'undelivered-alert: refused: %s\n' "$*" >&2; exit 1; }
[ -d "$STATE" ] && [ ! -L "$STATE" ] || refuse "the home has no state directory at $STATE"
if [ -L "$SHIM" ] || { [ -e "$SHIM" ] && [ ! -f "$SHIM" ]; }; then refuse "$SHIM is not a regular file; move it aside and run this again"; fi
SHIM_TEXT=$(printf '#!/usr/bin/env bash\nexec %q check %q\n' "$DEST/undelivered-alert.sh" "$FMH")
if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/undelivered-alert.sh -> $DEST/undelivered-alert.sh"
  echo "would write: $SHIM:"; printf '%s\n' "$SHIM_TEXT" | sed 's/^/  /'
  echo "would run: env -u JG_STATE_OVERRIDE JG_HOME=$FMH $FMH/bin/jg-check-register.sh $ID"
  echo "dry run: nothing written"; exit 0
fi
backup=''
if [ -f "$SHIM" ]; then backup=$(mktemp "$STATE/.jg-$ID-install.XXXXXX") || refuse "cannot write in $STATE"; cp -p "$SHIM" "$backup"; fi
trap '[ -z "$backup" ] || rm -f -- "$backup"' EXIT
mkdir -p "$DEST"
install -m 755 "$SRC/undelivered-alert.sh" "$DEST/undelivered-alert.sh"
printf '%s\n' "$SHIM_TEXT" > "$SHIM"
chmod 700 "$SHIM"
if ! env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" "$ID"; then
  if [ -n "$backup" ]; then cp -p "$backup" "$SHIM"; else rm -f -- "$SHIM"; fi
  refuse "the check could not be registered; the home's previous wiring is back"
fi
echo "undelivered-alert: wired $FMH"
