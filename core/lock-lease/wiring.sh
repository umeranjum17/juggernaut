#!/usr/bin/env bash
# Install or update the lock-lease check for this user and point one juggernaut home's
# state/lock-lease.check.sh at it through an exec shim, backing up a replaced check first, then register it.
# Idempotent. Usage: wiring.sh [--dry-run] <jg-home>

set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-register.sh" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-lock-lease
CHECK=$FMH/state/lock-lease.check.sh
SHIM=$(printf '#!/usr/bin/env bash\nexec %q %q\n' "$DEST/lock-lease.check.sh" "$FMH")
BAK=
[ ! -e "$CHECK" ] || [ "$(cat "$CHECK")" = "$SHIM" ] || BAK=$CHECK.bak-lock-lease-$(date +%s)

if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/lock-lease.check.sh -> $DEST/lock-lease.check.sh"
  [ -z "$BAK" ] || echo "would back up: $CHECK -> $BAK"
  echo "would write: $CHECK:"
  printf '%s\n' "$SHIM" | sed 's/^/  /'
  echo "would run: $FMH/bin/jg-check-register.sh lock-lease"
  echo "dry run: nothing written"
  exit 0
fi
mkdir -p "$DEST"
install -m 755 "$SRC/lock-lease.check.sh" "$DEST/lock-lease.check.sh"
[ -z "$BAK" ] || { cp -p "$CHECK" "$BAK"; echo "backed up: $BAK"; }
printf '%s\n' "$SHIM" > "$CHECK"
chmod 700 "$CHECK"
# An JG_STATE_OVERRIDE in the caller env, even empty, would register away from FMH/state.
env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" lock-lease
echo "installed: $CHECK -> $DEST/lock-lease.check.sh"
