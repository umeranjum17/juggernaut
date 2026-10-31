#!/usr/bin/env bash
# account-pool unwiring.sh - the feature holds no state outside its checkout. Without it the hook lines
# are no-ops and workers launch on the ambient account; config/account-pool and the pool folder are the
# operator's and stay. Usage: unwiring.sh <jg-home>
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

echo "account-pool: nothing to remove. Delete ${JG_ADDONS_DIR:-${1:-<jg-home>}/projects/juggernaut-addons}/account-pool to turn the pool off."
