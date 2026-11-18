#!/usr/bin/env bash
# The item store: its proofs, the jg-item CLI journey and the wiring dry run (the simulator's seeds are in
# tests/item-store-sim-e2e.test.sh, so each file stays inside the runner's limit for its class).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fail=0
bash "$ROOT/core/item-store/tests/item-store.test.sh" || fail=1
bash "$ROOT/core/item-store/tests/jg-item-cli.test.sh" || fail=1
bash "$ROOT/core/item-store/tests/wiring.test.sh" || fail=1
exit "$fail"
