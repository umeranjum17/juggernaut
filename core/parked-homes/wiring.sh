#!/usr/bin/env bash
# parked-homes wiring.sh - verify the parked-homes wiring for one juggernaut
# home. It changes nothing: the feature works through the fork's shim sourcing
# this checkout, so the only install state is (1) this checkout reachable from
# the home, (2) the fork hooks merged, (3) config/parked-homes readable.
#
# Usage: wiring.sh [--dry-run] <jg-home>
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -u

die() { echo "parked-homes install: $*" >&2; exit 1; }

home=${1:-${JG_HOME:-}}
[ -n "$home" ] && [ -d "$home" ] || die "usage: wiring.sh <jg-home>"
home=$(cd "$home" && pwd) || die "cannot read $home"
JG_HOME=$home

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
lib="$here/parked-homes/bin/jg-parked-homes-lib.sh"
[ -f "$lib" ] || die "this checkout is missing parked-homes/bin/jg-parked-homes-lib.sh (run from the juggernaut-addons checkout)"

status=0
say() { printf '%s\n' "$*"; }
bad() { printf 'MISSING: %s\n' "$*"; status=1; }

addons="${JG_ADDONS_DIR:-$home/projects/juggernaut-addons}"
if [ -f "$addons/parked-homes/bin/jg-parked-homes-lib.sh" ]; then
  same=0
  [ "$(cat "$addons/parked-homes/bin/jg-parked-homes-lib.sh" 2>/dev/null)" = "$(cat "$lib")" ] && same=1
  say "feature checkout: $addons (lib $([ "$same" = 1 ] && echo matches || echo DIFFERS-FROM-this-checkout))"
else
  bad "feature checkout reachable at $addons/parked-homes (set JG_ADDONS_DIR or update projects/juggernaut-addons)"
fi

if [ -f "$home/bin/jg-parked-homes-lib.sh" ] &&
   grep -q "parked-homes/bin/jg-parked-homes-lib.sh" "$home/bin/jg-parked-homes-lib.sh"; then
  say "fork shim: $home/bin/jg-parked-homes-lib.sh present"
else
  bad "fork shim at $home/bin/jg-parked-homes-lib.sh (merge the parked-homes fork PR first)"
fi

file="$home/config/parked-homes"
if [ -f "$file" ]; then
  say "parked file: $file"
  grep -Ev '^[[:space:]]*(#|$)' "$file" | sed 's/^/  parked: /'
else
  say "parked file: $file absent (nothing is parked)"
fi

[ "$status" = 0 ] && say "wiring complete" || say "wiring incomplete"
exit "$status"
