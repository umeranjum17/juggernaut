#!/usr/bin/env bash
# done-done journey: a required gate shard over its wall-clock budget is a warning, never a red. It runs every script it
# selected, prints one JG_TEST_OVERRUN line with the host load, and only a failed test turns it red; the trunk verify moves
# the green pin over it and keeps one machine-load row per shard (data/trunk/load-<project>.tsv).
#   tests/jg-test-run.test.sh     the real bin/jg-test-run.sh --required-shards over throwaway repositories with a 2 s
#                                 budget: nine passing scripts that each sleep 3 s all run and the gate passes with eight
#                                 warnings; a failed script over the budget stays red and runs once.
#   tests/jg-trunk-verify.test.sh the real bin/jg-trunk.sh verify over a gate replaying trunk-v3 at 20eb94ae6054 (eight
#                                 shards at 601 to 651 s of 600 s, failed=0): the pin moves, one warning, eight load rows;
#                                 a failed test over the budget holds the pin.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
{ env -u JG_TASK_ID bash "$root/tests/jg-test-run.test.sh" && env -u JG_TASK_ID bash "$root/tests/jg-trunk-verify.test.sh"; } > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "throwaway git repositories gated by the real bin/jg-test-run.sh --required-shards with a 2000 ms shard budget, and a throwaway trunk home verified by the real bin/jg-trunk.sh",
 "steps": ["run nine passing scripts that each sleep past the budget, and require all nine to run, eight overrun warnings with the host load, and a green gate", "run a failing script that sleeps past the budget, and require a red gate with the script run once", "verify a trunk commit whose gate replays the eight over-budget shards of 20eb94ae6054 with no failed test, and require the pin to move, one warning and eight machine-load rows", "verify a commit with a failed test over the budget, and require the pin to hold"],
 "result": "a shard slowed by the machine runs every script and is a recorded warning, never a red, while a failed test stays red"}
JSON
exit "$rc"
