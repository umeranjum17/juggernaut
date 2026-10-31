#!/usr/bin/env bash
# Remove key-in-env-check's home shim, check registration, and installed script. Usage: unwiring.sh [--dry-run]
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }; [ "$#" -eq 0 ] || { echo 'usage: unwiring.sh [--dry-run]' >&2; exit 2; }
JG_HOME=${JG_HOME:?set JG_HOME to the juggernaut home}; DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-key-in-env-check; f=$JG_HOME/state/key-in-env-check.check.sh
if [ -e "$f" ]; then
  [ -x "$JG_HOME/bin/jg-check-unregister.sh" ] || { echo "remove manually: $f" >&2; exit 1; }
  if [ "$DRY" -eq 1 ]; then echo "would run: $JG_HOME/bin/jg-check-unregister.sh key-in-env-check"; else env -u JG_STATE_OVERRIDE JG_HOME="$JG_HOME" "$JG_HOME/bin/jg-check-unregister.sh" key-in-env-check; fi
fi
[ ! -e "$DEST/key-in-env-check" ] || { echo "remove: $DEST/key-in-env-check"; [ "$DRY" -eq 1 ] || rm -f -- "$DEST/key-in-env-check"; }
[ "$DRY" -eq 1 ] || rmdir "$DEST" 2>/dev/null || true
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
