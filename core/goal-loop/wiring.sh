#!/usr/bin/env bash
# Install or update goal-loop: copy the check to ${XDG_DATA_HOME:-~/.local/share}/jg-goal-loop/goal-loop.sh, write
# the home's state/goal-loop.check.sh as a shim that runs it for this home (mode 700), and register the check
# with the home's bin/jg-check-register.sh. Idempotent. The shim is the whole install: it never starts a Goal.
# Usage: wiring.sh [--dry-run] <jg-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-register.sh" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-goal-loop
SHIM=$FMH/state/goal-loop.check.sh
SHIM_TEXT=$(printf '#!/usr/bin/env bash\nexec %q check %q\n' "$DEST/goal-loop.sh" "$FMH")
if [ "$DRY" -eq 1 ]; then
  echo "would copy $SRC/goal-loop.sh -> $DEST/goal-loop.sh, write $SHIM (mode 700) and run $FMH/bin/jg-check-register.sh goal-loop"
  exit 0
fi
[ -d "$FMH/state" ] && [ ! -L "$SHIM" ] || { echo "goal-loop: refused: $FMH/state is missing or $SHIM is a link" >&2; exit 1; }
mkdir -p "$DEST"
install -m 755 "$SRC/goal-loop.sh" "$DEST/goal-loop.sh"
printf '%s\n' "$SHIM_TEXT" > "$SHIM"
chmod 700 "$SHIM"
env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" goal-loop \
  || { rm -f -- "$SHIM"; echo "goal-loop: refused: the check could not be registered" >&2; exit 1; }
echo "goal-loop: wired $FMH (check $DEST/goal-loop.sh)"
