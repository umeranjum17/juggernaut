#!/usr/bin/env bash
# run-proof.sh: the load journey proof for done-done. Runs the behavior test, then one real journey over four lab
# homes and eight lanes, and keeps the per-fault results (faults.jsonl) and the summary (summary.json) as evidence.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
mkdir -p "$evidence"
bash "$repo/tests/jg-load-journey.test.sh"
bash "$repo/bin/jg-load-journey.sh" run --homes 4 --lanes 8 --out "$evidence"
