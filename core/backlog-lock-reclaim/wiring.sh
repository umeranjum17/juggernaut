#!/usr/bin/env bash
# Install or update the backlog-lock-reclaim check for this user and point one juggernaut home's
# state/backlog-lock-reclaim.check.sh at it through an exec shim, backing up a replaced check first, then register it.
# Idempotent. Usage: wiring.sh [--dry-run] <jg-home>
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
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-backlog-lock-reclaim
CHECK=$FMH/state/backlog-lock-reclaim.check.sh
SHIM=$(printf '#!/usr/bin/env bash\nexec %q %q\n' "$DEST/backlog-lock-reclaim.check.sh" "$FMH")
BAK=
[ ! -e "$CHECK" ] || [ "$(cat "$CHECK")" = "$SHIM" ] || BAK=$CHECK.bak-backlog-lock-reclaim-$(date +%s)

if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/backlog-lock-reclaim.check.sh -> $DEST/backlog-lock-reclaim.check.sh"
  [ -z "$BAK" ] || echo "would back up: $CHECK -> $BAK"
  echo "would write: $CHECK:"
  printf '%s\n' "$SHIM" | sed 's/^/  /'
  echo "would run: $FMH/bin/jg-check-register.sh backlog-lock-reclaim"
  echo "dry run: nothing written"
  exit 0
fi
mkdir -p "$DEST"
install -m 755 "$SRC/backlog-lock-reclaim.check.sh" "$DEST/backlog-lock-reclaim.check.sh"
[ -z "$BAK" ] || { cp -p "$CHECK" "$BAK"; echo "backed up: $BAK"; }
printf '%s\n' "$SHIM" > "$CHECK"
chmod 700 "$CHECK"
# An JG_STATE_OVERRIDE in the caller env, even empty, would register away from FMH/state.
env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" backlog-lock-reclaim
echo "installed: $CHECK -> $DEST/backlog-lock-reclaim.check.sh"
