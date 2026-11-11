#!/usr/bin/env bash
# Check a lead home's required watcher checks and repair an absent shim.
# Usage: jg-required-checks.sh <home> [--detect-only]
set -u
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || exit 2
home=$1
[ -s "$home/.jg-squad-lead-home" ] || exit 0
[ "$(tr -d '[:space:]' < "$home/.jg-squad-lead-home")" != main ] || exit 0
[ -d "$home/state" ] && [ ! -L "$home/state" ] || exit 1
check=$home/state/trunk-latency.check.sh
[ ! -e "$check" ] && [ ! -L "$check" ] || exit 0
if [ "${2:-}" = --detect-only ]; then
  printf 'required check missing: trunk-latency\n'
  exit 0
fi
exec 8>"$home/state/.required-checks.lock" || exit 1
flock -n 8 || exit 0
[ ! -e "$check" ] && [ ! -L "$check" ] || exit 0
printf 'required check missing: trunk-latency\n'
wire=$home/core/trunk-latency/wiring.sh
home_real=$(cd "$home" && pwd -P) || exit 1
wire_dir=$(cd "${wire%/*}" 2>/dev/null && pwd -P) || wire_dir=
[ "$wire_dir" = "$home_real/core/trunk-latency" ] && [ -f "$wire" ] && [ ! -L "$wire" ] || { echo 'required check: home wiring script unavailable' >&2; exit 1; }
bash "$wire" "$home"
