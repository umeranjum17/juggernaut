#!/usr/bin/env bash
# Print the newest data/*retro*/report.md across the homes fleet-homes.sh lists, by
# mtime. No output when none exist. Usage: newest-retro-report.sh <main-home>
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo 'usage: newest-retro-report.sh <main-home>' >&2
  exit 2
fi
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

newest=
newest_m=0
while IFS= read -r home; do
  [ -n "$home" ] || continue
  for report in "$home"/data/*retro*/report.md; do
    [ -f "$report" ] || continue
    m=$(stat -c %Y "$report")
    if [ -z "$newest" ] || [ "$m" -gt "$newest_m" ]; then
      newest=$report
      newest_m=$m
    fi
  done
done < <("$here/fleet-homes.sh" "$1")

[ -n "$newest" ] && printf '%s\n' "$newest"
exit 0
