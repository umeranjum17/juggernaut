#!/usr/bin/env bash
# Retire the limit-prompt-move check from one juggernaut home (its check and trust binding); with --all, from every
# active home wiring.sh --all reaches, and then remove the installed copy. Idempotent.
# Usage: unwiring.sh [--all] <jg-home>
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
ALL=
[ "${1:-}" = --all ] && { ALL=--all; shift; }
[ "$#" -eq 1 ] && [ -d "$1/state" ] || { echo "usage: unwiring.sh [--all] <jg-home>" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-limit-prompt-move
while IFS=$'\t' read -r name home; do
  [ -x "$home/bin/jg-check-unregister.sh" ] || { echo "skipped: $name: $home has no bin/jg-check-unregister.sh" >&2; continue; }
  env -u JG_STATE_OVERRIDE JG_HOME="$home" "$home/bin/jg-check-unregister.sh" limit-prompt-move >/dev/null
  echo "uninstalled: $name: limit-prompt-move from $home"
done < <("$SRC/wiring.sh" ${ALL:+--all} --list "$1")
[ -z "$ALL" ] || {
  rm -f -- "$DEST/limit-prompt-move/limit-prompt-move" "$DEST/limit-prompt-move/check.sh" "$DEST/parked-homes/bin/jg-parked-homes-lib.sh"
  rmdir -- "$DEST/limit-prompt-move" "$DEST/parked-homes/bin" "$DEST/parked-homes" "$DEST" 2>/dev/null || true
}
