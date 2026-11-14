#!/usr/bin/env bash
# Which homes of the fleet are not at a project's last go-live commit, once that go-live is old enough that they should be.
# Usage: jg-trunk-live-lag.sh <project-dir> [minutes]      (JG_HOME and JG_ROOT_OVERRIDE as for jg-trunk.sh; minutes default 10)
#
# Reads the project's newest `live` row in data/trunk-in-use.tsv and lists the homes (bin/jg-fleet-homes-lib.sh) whose HEAD is not
# that commit. Prints nothing and exits 0 when every home is at it or the row is younger than <minutes>; otherwise prints one line,
# `lag: homes not In use at the last go-live <sha12>: <ids>`, and exits 1. The line holds no age, so an unchanged lag is the same line
# every time and the landing check's go-live step (core/trunk-landing) reports it once.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
# shellcheck source=bin/jg-compat.sh
. "$SCRIPT_DIR/jg-compat.sh"
# shellcheck source=bin/jg-squad-lead-parent-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-parent-lib.sh"
# shellcheck source=bin/jg-squad-lead-registry-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"
# shellcheck source=bin/jg-fleet-homes-lib.sh
. "$SCRIPT_DIR/jg-fleet-homes-lib.sh"
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 2; }
pn=$(basename "$1"); minutes=${2:-10}
case "$minutes" in ''|*[!0-9]*) echo "jg-trunk-live-lag: minutes must be a whole number" >&2; exit 2 ;; esac
read -r sha at <<< "$(awk -F'\t' -v p="$pn" '$1 == p && $4 ~ /^live/ { s = $2; t = $3 } END { print s, t + 0 }' "$DATA/trunk-in-use.tsv" 2>/dev/null || true)"
[ -n "${sha:-}" ] && [ $(( $(date +%s) - at )) -gt $(( minutes * 60 )) ] || exit 0
behind=""
while IFS=$'\t' read -r _ id dir; do
  [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" = "$sha" ] || behind="$behind $id"
done < <(jg_fleet_homes "$JG_HOME" "$JG_ROOT")
[ -z "$behind" ] || { echo "lag: homes not In use at the last go-live ${sha:0:12}:$behind"; exit 1; }
