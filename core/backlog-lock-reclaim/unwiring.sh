#!/usr/bin/env bash
# Retire the backlog-lock-reclaim check from one juggernaut home (its check and trust binding), then remove the installed
# copy. Idempotent. Usage: unwiring.sh <jg-home>
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-unregister.sh" ] || { echo "usage: unwiring.sh <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-backlog-lock-reclaim
env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-unregister.sh" backlog-lock-reclaim
rm -f -- "$DEST/backlog-lock-reclaim.check.sh"
rmdir -- "$DEST" 2>/dev/null || true
echo "uninstalled: backlog-lock-reclaim from $FMH"
