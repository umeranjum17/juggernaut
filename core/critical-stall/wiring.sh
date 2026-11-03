#!/usr/bin/env bash
# Install or update the critical-stall watcher check in one juggernaut home. Idempotent.
# Usage: wiring.sh [--dry-run] <jg-home>
# Copies critical-stall.sh to ${XDG_DATA_HOME:-~/.local/share}/jg-critical-stall/, writes the home's
# state/critical-stall.check.sh as a one-line shim that execs it (mode 700), and registers the check with
# the home's bin/jg-check-register.sh; a registration the register script refuses puts the old shim back.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-register.sh" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-critical-stall
SHIM=$FMH/state/critical-stall.check.sh
TEXT=$(printf '#!/usr/bin/env bash\nexec %q check %q\n' "$DEST/critical-stall.sh" "$FMH")
[ -d "$FMH/state" ] && [ ! -L "$FMH/state" ] || { echo "critical-stall: refused: $FMH has no state directory" >&2; exit 1; }
if [ -L "$SHIM" ] || { [ -e "$SHIM" ] && [ ! -f "$SHIM" ]; }; then
  echo "critical-stall: refused: $SHIM is not a regular file; move it aside and run this again" >&2; exit 1
fi
if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/critical-stall.sh -> $DEST/critical-stall.sh"
  printf 'would write: %s:\n%s\n' "$SHIM" "$TEXT" | sed '2,$s/^/  /'
  echo "would run: env -u JG_STATE_OVERRIDE JG_HOME=$FMH $FMH/bin/jg-check-register.sh critical-stall"
  echo "dry run: nothing written"
  exit 0
fi
backup=''
[ ! -f "$SHIM" ] || { backup=$(mktemp "$FMH/state/.jg-critical-stall.XXXXXX"); cp -p "$SHIM" "$backup"; }
trap '[ -z "$backup" ] || rm -f -- "$backup"' EXIT
mkdir -p "$DEST"
install -m 755 "$SRC/critical-stall.sh" "$DEST/critical-stall.sh"
printf '%s\n' "$TEXT" > "$SHIM"
chmod 700 "$SHIM"
if ! env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" critical-stall; then
  if [ -n "$backup" ]; then cp -p "$backup" "$SHIM"; else rm -f -- "$SHIM"; fi
  echo "critical-stall: refused: the check could not be registered; the home's previous wiring is back" >&2; exit 1
fi
echo "critical-stall: wired $FMH (check $DEST/critical-stall.sh)"
