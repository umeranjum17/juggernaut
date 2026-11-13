#!/usr/bin/env bash
# Install or update the wake-rollup watcher check in one juggernaut home. Idempotent.
# Usage: wiring.sh [--dry-run] <jg-home>
# Copies rollup.sh to ${XDG_DATA_HOME:-~/.local/share}/jg-wake-rollup/, writes the home's
# state/wake-rollup.check.sh as a one-line shim that execs it (mode 700), and registers the check with
# the home's bin/jg-check-register.sh; a registration the register script refuses puts the old shim back.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-register.sh" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-wake-rollup
SHIM=$FMH/state/wake-rollup.check.sh
TEXT=$(printf '#!/usr/bin/env bash\nexec %q check %q\n' "$DEST/rollup.sh" "$FMH")
[ -d "$FMH/state" ] && [ ! -L "$FMH/state" ] || { echo "wake-rollup: refused: $FMH has no state directory" >&2; exit 1; }
if [ -L "$SHIM" ] || { [ -e "$SHIM" ] && [ ! -f "$SHIM" ]; }; then
  echo "wake-rollup: refused: $SHIM is not a regular file; move it aside and run this again" >&2; exit 1
fi
if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/rollup.sh -> $DEST/rollup.sh"
  printf 'would write: %s:\n%s\n' "$SHIM" "$TEXT" | sed '2,$s/^/  /'
  echo "would run: env -u JG_STATE_OVERRIDE JG_HOME=$FMH $FMH/bin/jg-check-register.sh wake-rollup"
  echo "dry run: nothing written"
  exit 0
fi
backup=''
[ ! -f "$SHIM" ] || { backup=$(mktemp "$FMH/state/.jg-wake-rollup.XXXXXX"); cp -p "$SHIM" "$backup"; }
trap '[ -z "$backup" ] || rm -f -- "$backup"' EXIT
mkdir -p "$DEST"
install -m 755 "$SRC/rollup.sh" "$DEST/rollup.sh"
printf '%s\n' "$TEXT" > "$SHIM"
chmod 700 "$SHIM"
if ! env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" wake-rollup; then
  if [ -n "$backup" ]; then cp -p "$backup" "$SHIM"; else rm -f -- "$SHIM"; fi
  echo "wake-rollup: refused: the check could not be registered; the home's previous wiring is back" >&2; exit 1
fi
echo "wake-rollup: wired $FMH (check $DEST/rollup.sh)"
