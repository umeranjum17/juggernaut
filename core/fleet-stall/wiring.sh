#!/usr/bin/env bash
# Install or update fleet-stall: copy the check to
# ${XDG_DATA_HOME:-~/.local/share}/jg-fleet-stall/fleet-stall-check, write the home's
# state/fleet-stall.check.sh as a one-line shim that execs it (mode 700, the old
# file kept as .bak-fleet-stall-<stamp> when it differs), and register the
# fleet-stall check with the home's bin/jg-check-register.sh. Idempotent.
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
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/fleet-stall-check
dest=${XDG_DATA_HOME:-$HOME/.local/share}/jg-fleet-stall/fleet-stall-check
check=$JG_HOME/state/fleet-stall.check.sh
shim=$(printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$dest")
if [ "$dry" = 1 ]; then
  echo "dry-run: would copy $src -> $dest, write $check as a shim to it (mode 700) and register the fleet-stall check"
  exit 0
fi
mkdir -p "${dest%/*}" "$JG_HOME/state"
install -m 755 "$src" "$dest"
if [ "$(cat "$check" 2>/dev/null)" != "$shim" ]; then
  bak=$check.bak-fleet-stall-$(date +%s)
  [ ! -e "$check" ] || { cp -p "$check" "$bak"; echo "backup: $bak"; }
  printf '%s\n' "$shim" > "$check"
fi
chmod 700 "$check"
if [ -x "$JG_HOME/bin/jg-check-register.sh" ]; then
  env -u JG_STATE_OVERRIDE "$JG_HOME/bin/jg-check-register.sh" fleet-stall
fi
echo "installed $dest; $check execs it"
