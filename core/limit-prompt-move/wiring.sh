#!/usr/bin/env bash
# Install or update the limit-prompt-move check for this user and point a juggernaut home's
# state/limit-prompt-move.check.sh at it through an exec shim (a replaced check is backed up), then register it.
# --all reaches every active home from <jg-home>: the home itself and each local squad_lead home its
# data/squad_leads.md lists, minus the ones its config/parked-homes parks; a remote home is skipped and named.
# --list prints the homes it would reach, one "<name><TAB><dir>" line each, and writes nothing. Idempotent.
# Usage: wiring.sh [--all] [--list] <jg-home>
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
ALL=0 LIST=0
while [ "$#" -gt 1 ]; do
  case $1 in --all) ALL=1 ;; --list) LIST=1 ;; *) break ;; esac
  shift
done
[ "$#" -eq 1 ] && [ -d "$1/state" ] || { echo "usage: wiring.sh [--all] [--list] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-limit-prompt-move
ID=limit-prompt-move

homes() {
  local line name dir re='^- ([^[:space:]]+) - .*\((host:[^;]*;[[:space:]]*root:[^;]*;[[:space:]]*)?home: ([^;]*[^;[:space:]])[[:space:]]*;'
  printf 'main\t%s\n' "$FMH"
  [ "$ALL" -eq 1 ] && [ -f "$FMH/data/squad_leads.md" ] || return 0
  # shellcheck source=parked-homes/bin/jg-parked-homes-lib.sh
  . "$SRC/parked-homes/bin/jg-parked-homes-lib.sh"
  while IFS= read -r line; do
    [[ $line =~ $re ]] || continue
    name=${BASH_REMATCH[1]} dir=${BASH_REMATCH[3]}
    if [ -n "${BASH_REMATCH[2]}" ]; then echo "skipped: $name: a remote home, install it on its host" >&2
    elif JG_HOME=$FMH jg_parked_home "$name"; then echo "skipped: $name: parked" >&2
    else printf '%s\t%s\n' "$name" "$dir"
    fi
  done <"$FMH/data/squad_leads.md"
}

[ "$LIST" -eq 0 ] || { homes; exit 0; }
install -D -m 755 "$SRC/$ID/$ID" "$DEST/$ID/$ID"
install -D -m 755 "$SRC/$ID/check.sh" "$DEST/$ID/check.sh"
install -D -m 644 "$SRC/parked-homes/bin/jg-parked-homes-lib.sh" "$DEST/parked-homes/bin/jg-parked-homes-lib.sh"
install -D -m 644 "$SRC/account-pool/bin/jg-account-pool-lib.sh" "$DEST/account-pool/bin/jg-account-pool-lib.sh"
fails=0
while IFS=$'\t' read -r name home; do
  [ -x "$home/bin/jg-check-register.sh" ] && [ -d "$home/state" ] || {
    echo "skipped: $name: $home has no bin/jg-check-register.sh or state/" >&2; fails=$((fails + 1)); continue; }
  home=$(cd "$home" && pwd -P)
  check=$home/state/$ID.check.sh
  shim=$(printf '#!/usr/bin/env bash\nexec %q %q\n' "$DEST/$ID/check.sh" "$home")
  if [ -e "$check" ] && [ "$(cat "$check")" != "$shim" ]; then
    cp -p "$check" "$check.bak-$ID-$(date +%s)" && echo "backed up: $check.bak-$ID-*"
  fi
  printf '%s\n' "$shim" >"$check"
  chmod 700 "$check"
  if env -u JG_STATE_OVERRIDE JG_HOME="$home" "$home/bin/jg-check-register.sh" "$ID" >/dev/null; then
    echo "installed: $name: $check -> $DEST/$ID/check.sh"
  else
    echo "failed: $name: $home/bin/jg-check-register.sh $ID refused the check" >&2; fails=$((fails + 1))
  fi
done < <(homes)
[ "$fails" -eq 0 ]
