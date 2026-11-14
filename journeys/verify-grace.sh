#!/usr/bin/env bash
# done-done journey: the verify grace (H39). Runs tests/jg-trunk-verify-grace.test.sh and keeps its output as run evidence.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ev=${DONE_DONE_EVIDENCE_ROOT:?DONE_DONE_EVIDENCE_ROOT must name the run folder}
rc=0
(cd "$root" && bash tests/jg-trunk-verify-grace.test.sh) > "$ev/grace.log" 2>&1 || rc=$?
cat "$ev/grace.log"
printf '%s\n' '{"target": {"version": "core/trunk-verify/grace.sh at this head"}, "start": "a fixture home with a real git project, the real landing check, the real verify and the real ticket filer", "steps": ["verify a failed script with verify-grace unset: red, no ticket", "set verify-grace=2: the same failure passes and the verdict names the script and its one ticket", "a shard that exited non-zero with no counted failure, a missing shard result and three failed scripts are each red"], "result": "grace.log shows the green verdict naming tests/a.test.sh with its ticket and the three reds"}' > "$ev/steps.json"
exit "$rc"
