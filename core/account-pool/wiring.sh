#!/usr/bin/env bash
# account-pool wiring.sh - verify the wiring for one juggernaut home; changes nothing. The feature
# works through hook lines in the home's bin/jg-spawn.sh and bin/jg-control.sh sourcing this checkout.
# Usage: wiring.sh <jg-home>
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -u
home=${1:-${JG_HOME:-}}
[ -n "$home" ] && [ -d "$home" ] || { echo "account-pool install: usage: wiring.sh <jg-home>" >&2; exit 1; }
lib=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/jg-account-pool-lib.sh
addons=${JG_ADDONS_DIR:-$home/projects/juggernaut-addons}
status=0
if [ -f "$addons/account-pool/bin/jg-account-pool-lib.sh" ]; then
  cmp -s "$addons/account-pool/bin/jg-account-pool-lib.sh" "$lib" && echo "feature checkout: $addons (lib matches)" || echo "feature checkout: $addons (lib DIFFERS from this checkout)"
else
  echo "MISSING: feature checkout at $addons/account-pool (set JG_ADDONS_DIR)"; status=1
fi
for f in jg-spawn.sh jg-control.sh; do
  grep -q 'jg_account_hook' "$home/bin/$f" 2>/dev/null && echo "fork hook: bin/$f calls jg_account_hook" || { echo "MISSING: jg_account_hook lines in $home/bin/$f"; status=1; }
done
[ -f "$home/config/account-pool" ] && echo "pool file: $home/config/account-pool" || echo "pool file: absent (the pool is off)"
exit "$status"
