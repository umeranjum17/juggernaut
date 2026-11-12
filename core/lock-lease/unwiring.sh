#!/usr/bin/env bash
# Retire the lock-lease check from one juggernaut home (its check and trust binding), then remove the installed
# copy. Idempotent. Usage: unwiring.sh <jg-home>

set -euo pipefail
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-unregister.sh" ] || { echo "usage: unwiring.sh <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-lock-lease
env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-unregister.sh" lock-lease
rm -f -- "$DEST/lock-lease.check.sh"
rmdir -- "$DEST" 2>/dev/null || true
echo "uninstalled: lock-lease from $FMH"
