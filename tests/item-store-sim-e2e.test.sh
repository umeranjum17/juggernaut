#!/usr/bin/env bash
# The item store's simulator, end to end: one fleet day per seed on a fake clock, every fault on (seeds 0-2, then each
# seed in core/item-store/tests/sim-seeds.txt). The longer run (seeds 0-19 and the clock mutant) is
# core/item-store/tests/item-store-sim.test.sh.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fail=0
sim() {   # <seeds>
  local out
  out=$(python3 -I "$ROOT/core/item-store/sim/sim.py" --seeds "$1") || { echo "FAIL sim $1: exit $?"; fail=1; return; }
  if printf '%s' "$out" | python3 -I -c 'import json,sys; assert json.load(sys.stdin)["failed"]==0'; then
    echo "ok sim seeds $1"
  else
    echo "FAIL sim $1: failed is not 0"; fail=1
  fi
}
sim 0-2
while read -r seed; do [ -z "$seed" ] || sim "$seed"; done < "$ROOT/core/item-store/tests/sim-seeds.txt"
exit "$fail"
