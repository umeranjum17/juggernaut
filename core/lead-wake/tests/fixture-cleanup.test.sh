#!/usr/bin/env bash
# Proves fixture-cleanup.sh against the two shapes that broke the lead-wake
# journey: a writer that refills the tree during removal (must be removed, run
# still green), and a writer that never stops (must warn with the path, still
# green).
set -uo pipefail
cleanup=$(cd "$(dirname "$0")" && pwd)/fixture-cleanup.sh

fail() { echo "not ok - $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

# A late writer recreates the state directory while the tree is being removed.
d=$(mktemp -d)
mkdir -p "$d/absent/state"
(
  for _ in 1 2 3 4 5 6 7 8; do
    mkdir -p "$d/absent/state" 2>/dev/null
    : > "$d/absent/state/late" 2>/dev/null
    sleep 0.03
  done
) &
writer=$!
out=$(bash "$cleanup" "$d" 2>&1)
rc=$?
wait "$writer" 2>/dev/null || true
[ "$rc" -eq 0 ] || fail "cleanup failed on a late writer: $out"
[ -z "$out" ] || fail "a removable fixture still warned: $out"
[ ! -e "$d" ] || fail "fixture survived a late writer: $d"
ok "cleanup removes a tree a late writer refills, and the run stays green"

# A writer that never stops must warn with the path rather than fail the run.
d=$(mktemp -d)
stop="$d.stop"
: > "$stop"
(
  while [ -e "$stop" ]; do
    mkdir -p "$d/stuck" 2>/dev/null
    : > "$d/stuck/late" 2>/dev/null
    sleep 0.01
  done
) &
writer=$!
out=$(bash "$cleanup" "$d" 2>&1)
rc=$?
rm -f -- "$stop"
wait "$writer" 2>/dev/null || true
[ "$rc" -eq 0 ] || fail "cleanup failed instead of warning: $out"
case "$out" in
  *"warning: fixture cleanup left $d"*) ok "an unremovable fixture is warned by name, not failed" ;;
  *) fail "no warning naming $d: $out" ;;
esac
rm -rf -- "$d"
