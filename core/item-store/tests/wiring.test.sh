#!/usr/bin/env bash
# wiring.sh and unwiring.sh in --dry-run against a temporary home built from this checkout (bin and core linked,
# an empty state): they name the register and unregister calls and write nothing.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
d=$(mktemp -d) || exit 1
trap 'rm -rf -- "$d"' EXIT
T=$d/home; mkdir -p "$T/state"; ln -sn "$ROOT/bin" "$T/bin"; ln -sn "$ROOT/core" "$T/core"
T=$(cd "$T" && pwd -P)
fail=0
out=$("$ROOT/core/item-store/wiring.sh" --dry-run "$T" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qxF "would run: env -u JG_STATE_OVERRIDE JG_HOME=$T $T/bin/jg-check-register.sh item-store" \
   && printf '%s\n' "$out" | tail -n 1 | grep -qx 'dry run: nothing written' && [ -z "$(ls -A "$T/state")" ]; then
  echo "ok wiring-dry-run"
else
  echo "FAIL wiring-dry-run: exit $rc [$out]"; fail=1
fi
out=$("$ROOT/core/item-store/unwiring.sh" --dry-run "$T" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx "item-store: not wired in $T"; then echo "ok unwiring-dry-run"; else echo "FAIL unwiring-dry-run: exit $rc [$out]"; fail=1; fi
out=$("$ROOT/core/item-store/wiring.sh" --dry-run "$d/nohome" 2>&1); rc=$?
[ "$rc" -eq 2 ] && echo "ok wiring-usage" || { echo "FAIL wiring-usage: exit $rc"; fail=1; }
exit "$fail"
