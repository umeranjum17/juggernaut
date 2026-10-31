#!/usr/bin/env bash
# Install the quota-failover watcher for this user and register an exec shim to it as a home's quota-failover-watch
# check (a different check is backed up first). --all: the home and each local, unparked home its data/squad_leads.md
# lists (a remote one is named and skipped); --list prints those homes and writes nothing. Idempotent.
# Usage: wiring.sh [--dry-run] [--all] [--list] <jg-home>
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
DRY=0 ALL=0 LIST=0
while [ "$#" -gt 1 ]; do
  case $1 in --dry-run) DRY=1 ;; --all) ALL=1 ;; --list) LIST=1 ;; *) break ;; esac
  shift
done
[ "$#" -eq 1 ] && [ -d "$1/state" ] || { echo "usage: wiring.sh [--dry-run] [--all] [--list] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-quota-failover
ID=quota-failover-watch
# The sibling feature libs the watcher sources by its own path, copied beside it in the same layout.
LIBS="parked-homes/bin/jg-parked-homes-lib.sh account-pool/bin/jg-account-pool-lib.sh account-pool/bin/jg-pool-claude-env.sh"

# homes: "<name><TAB><dir>" for <jg-home> and, with --all, each active local squad_lead home it lists.
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
if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/quota-failover/{quota-failover,check.sh} and the sibling libs it sources ($LIBS) -> $DEST"
else
  install -D -m 755 "$SRC/quota-failover/quota-failover" "$DEST/quota-failover/quota-failover"
  install -D -m 755 "$SRC/quota-failover/check.sh" "$DEST/quota-failover/check.sh"
  for lib in $LIBS; do install -D -m 644 "$SRC/$lib" "$DEST/$lib"; done
fi
fails=0
while IFS=$'\t' read -r name home; do
  [ -x "$home/bin/jg-check-register.sh" ] && [ -d "$home/state" ] || {
    echo "skipped: $name: $home has no bin/jg-check-register.sh or state/" >&2; fails=$((fails + 1)); continue; }
  home=$(cd "$home" && pwd -P)
  check=$home/state/$ID.check.sh
  shim=$(printf '#!/usr/bin/env bash\nexec %q %q\n' "$DEST/quota-failover/check.sh" "$home")
  bak=
  [ ! -e "$check" ] || [ "$(cat "$check")" = "$shim" ] || bak=$check.bak-$ID-$(date +%s)
  if [ "$DRY" -eq 1 ]; then
    [ -z "$bak" ] || echo "would back up: $check -> $bak"
    echo "would write: $check: exec $DEST/quota-failover/check.sh $home"
    echo "would run: $home/bin/jg-check-register.sh $ID"
    continue
  fi
  [ -z "$bak" ] || { cp -p "$check" "$bak"; echo "backed up: $bak"; }
  printf '%s\n' "$shim" >"$check"
  chmod 700 "$check"
  # An JG_STATE_OVERRIDE in the caller env, even empty, would register away from the home's state.
  if env -u JG_STATE_OVERRIDE JG_HOME="$home" "$home/bin/jg-check-register.sh" "$ID" >/dev/null; then
    echo "installed: $name: $check -> $DEST/quota-failover/check.sh"
  else
    echo "failed: $name: $home/bin/jg-check-register.sh $ID refused the check" >&2; fails=$((fails + 1))
  fi
done < <(homes)
[ "$DRY" -eq 0 ] || echo "dry run: nothing written"
[ "$fails" -eq 0 ]
