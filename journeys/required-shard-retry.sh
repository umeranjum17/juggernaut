#!/usr/bin/env bash
# required-shard-retry: the required-shard runner and the trunk verify, each run through its real test script.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
{
  env -u JG_TASK_ID bash "$root/tests/jg-test-run.test.sh" || rc=1
  env -u JG_TASK_ID bash "$root/tests/jg-trunk-verify.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "throwaway repositories and a fixture home with the real jg-test-run.sh and jg-trunk.sh",
 "steps": ["run the required shards over budget with no failed test", "run the trunk verify over two landed changes that break together", "trace the red to the second change and revert it", "raise the line-red alert under its alert-line-red--proj key", "run the nightly whole run and raise line-red for the traced commit"],
 "result": "every case of jg-test-run and jg-trunk-verify passes, including the nightly line-red alert under its current key"}
JSON
exit "$rc"
