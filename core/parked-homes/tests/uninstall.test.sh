#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/user XDG_DATA_HOME=$d/data
home=$d/home
mkdir -p "$home/bin" "$home/config"
JG_ADDONS_DIR=$(cd "$SRC/.." && pwd -P)
export JG_ADDONS_DIR
printf '#!/bin/sh\n# parked-homes/bin/jg-parked-homes-lib.sh\n' >"$home/bin/jg-parked-homes-lib.sh"
printf '# fixture parked state\n' >"$home/config/parked-homes"
before=$(find "$home" -type f -exec sha256sum {} + | sort)
"$SRC/wiring.sh" "$home" >/dev/null
"$SRC/unwiring.sh" "$home" >/dev/null
"$SRC/unwiring.sh" "$home" >/dev/null
after=$(find "$home" -type f -exec sha256sum {} + | sort)
[ "$after" = "$before" ] || { echo 'FAIL: verify-only install/uninstall changed home state' >&2; exit 1; }
echo 'PASS parked-homes verify-only uninstall'
