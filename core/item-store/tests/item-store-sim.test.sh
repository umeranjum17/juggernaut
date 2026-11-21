#!/usr/bin/env bash
# The simulator: seeds 0-19, then each seed in sim-seeds.txt, then the clock mutant, the rates of seeds 0-2 against the profile, and the lease mutant.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$HERE/../../.." && pwd -P)
fail=0
sim() {   # <seeds>
  local out
  out=$(python3 -I "$ROOT/core/item-store/sim/sim.py" --seeds "$1") || { echo "FAIL sim $1: exit $?"; fail=1; return; }
  if printf '%s' "$out" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d["failed"]==0 and d["early_climbs"]==0, d'; then
    echo "ok sim seeds $1"
  else
    echo "FAIL sim $1: failed or early_climbs is not 0"; fail=1
  fi
}
sim 0-19
while read -r seed; do [ -z "$seed" ] || sim "$seed"; done < "$HERE/sim-seeds.txt"
out=$(python3 -I "$HERE/clock_mutant.py" 0-19) || { echo "FAIL clock_mutant: exit $?"; fail=1; }
if printf '%s' "$out" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d["caught"]==20, d'; then
  echo "ok clock_mutant caught 20"
else
  echo "FAIL clock_mutant: caught is not 20"; fail=1
fi
if python3 -I "$ROOT/core/item-store/sim/sim.py" --seeds 0-2 --rates >/dev/null 2>"${TMPDIR:-/tmp}/item-store-rates.$$"; then
  echo "ok rates"
else
  echo "FAIL rates: a kind is off the 14-17 Nov profile"; grep ' off$' "${TMPDIR:-/tmp}/item-store-rates.$$"; fail=1
fi
rm -f "${TMPDIR:-/tmp}/item-store-rates.$$"
out=$(python3 -I "$HERE/lease_mutant.py" 0-4) || { echo "FAIL lease_mutant: exit $?"; fail=1; }
if printf '%s' "$out" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d["caught"]==5 and d["by_invariant"]=={"I14": 5}, d'; then
  echo "ok lease_mutant caught 5"
else
  echo "FAIL lease_mutant: caught is not 5 by I14"; fail=1
fi
exit "$fail"
