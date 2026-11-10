#!/usr/bin/env bash
# Capture the real supervision pass that repairs a missing check.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/required-checks.log
env -u JG_TASK_ID bash "$root/tests/jg-stops.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target":{"version":"$(git -C "$root" rev-parse --short HEAD)"},"start":"a lead home without its latency check","steps":["read the session digest", "run the supervision pass", "run a second pass"],"result":"the missing check is named, installed and registered, and the next pass is silent"}
JSON
exit "$rc"
