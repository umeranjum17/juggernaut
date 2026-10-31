#!/usr/bin/env bash
# Install or update the drain CLI for this user, register its watcher check in one juggernaut home, and retire the
# three checks it replaces (nm-quiet, nm-update, nm-upgrade). Idempotent. Usage: wiring.sh [--dry-run] <jg-home>
# The check id sorts first so a check that wakes every sweep (a wake ends the sweep) cannot starve the drain.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-register.sh" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-nm-drain
ID=0-nm-drain
SHIM=$(printf '#!/usr/bin/env bash\nexec %q check %q\n' "$DEST/nm-drain.sh" "$FMH")

run() {
  if [ "$DRY" -eq 1 ]; then echo "would run: $*"; else "$@"; fi
}

if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/nm-drain.sh -> $DEST/nm-drain.sh"
  echo "would write: $FMH/state/$ID.check.sh:"
  printf '%s\n' "$SHIM" | sed 's/^/  /'
else
  mkdir -p "$DEST"
  install -m 755 "$SRC/nm-drain.sh" "$DEST/nm-drain.sh"
  printf '%s\n' "$SHIM" > "$FMH/state/$ID.check.sh"
  chmod 700 "$FMH/state/$ID.check.sh"
fi
# An JG_STATE_OVERRIDE in the caller env, even empty, would redirect the unregister away from FMH/state.
run env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" "$ID"
for old in nm-quiet nm-update nm-upgrade; do
  if [ -e "$FMH/state/$old.check.sh" ] || [ -e "$FMH/state/$old.check-trust" ]; then
    run env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-unregister.sh" "$old"
  else
    echo "absent: $FMH/state/$old.check.sh"
  fi
done
[ "$DRY" -eq 0 ] || echo "dry run: nothing written"
