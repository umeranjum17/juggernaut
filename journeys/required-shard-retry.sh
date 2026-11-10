#!/usr/bin/env bash
# done-done journey: a required gate shard that passes every script but runs over its wall-clock budget runs
# once more, and its second run counts. Real bin/jg-test-run.sh --required-shards runs over throwaway fixture
# repositories with a 2 s budget (JG_REQUIRED_SHARD_WALL_MS):
#   slow-once   the one script sleeps past the budget on its first run only: the shard is classed retry, runs
#               again, and the gate passes, with the first run kept as retried-shard-<k>.json.
#   slow-twice  the script runs past the budget every time: the second overrun is final and the gate is red.
#   slow-red    the script fails a test and runs past the budget: it is a red and never runs again.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
env -u JG_TASK_ID bash "$root/tests/jg-test-run.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "three throwaway git repositories, each adding one test script, gated by the real bin/jg-test-run.sh --required-shards with a 2000 ms shard budget",
 "steps": ["run a shard whose script passes but sleeps past the budget on its first run only, and require one rerun and a green gate", "run a shard whose script passes but always sleeps past the budget, and require a red gate naming the second overrun as final", "run a shard whose script fails a test and sleeps past the budget, and require a red gate with the script run once"],
 "result": "a shard slowed by the machine is retried once and no longer turns the gate red, while a second overrun or a failed test stays red"}
JSON
exit "$rc"
