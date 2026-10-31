#!/usr/bin/env bash
# Remove the Z.AI quota check from one juggernaut home. Usage: unwiring.sh [--dry-run]
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
JG_HOME=${JG_HOME:?set JG_HOME to the juggernaut home}; f=$JG_HOME/state/zai-quota.check.sh
if [ -e "$f" ]; then
  [ -x "$JG_HOME/bin/jg-check-unregister.sh" ] || { echo "remove manually: $f" >&2; exit 1; }
  if [ "$DRY" -eq 1 ]; then echo "would run: $JG_HOME/bin/jg-check-unregister.sh zai-quota"; else env -u JG_STATE_OVERRIDE JG_HOME="$JG_HOME" "$JG_HOME/bin/jg-check-unregister.sh" zai-quota; fi
fi
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
