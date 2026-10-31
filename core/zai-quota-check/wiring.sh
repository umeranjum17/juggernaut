#!/usr/bin/env bash
# Install or update zai-quota-check: copy the check into $JG_HOME/state/ as
# zai-quota.check.sh (mode 700, the state-check convention) and register the
# zai-quota check with the home's bin/jg-check-register.sh. Idempotent.
# Usage: wiring.sh [--dry-run]  (JG_HOME must name the home that runs it)
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
dry=0
[ "${1:-}" = --dry-run ] && dry=1
JG_HOME=${JG_HOME:?set JG_HOME to the juggernaut home that runs the check}
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/zai-quota-check
dest=$JG_HOME/state/zai-quota.check.sh
if [ "$dry" = 1 ]; then
  echo "dry-run: would copy $src -> $dest (mode 700) and register the zai-quota check"
  exit 0
fi
mkdir -p "$JG_HOME/state"
cp -p "$src" "$dest"
chmod 700 "$dest"
if [ -x "$JG_HOME/bin/jg-check-register.sh" ]; then
  "$JG_HOME/bin/jg-check-register.sh" zai-quota
fi
echo "installed $dest"
