#!/usr/bin/env bash
# done-done journey: one judge per commit (H29g). Runs tests/jg-trunk-judge.test.sh and keeps its output as run evidence.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ev=${DONE_DONE_EVIDENCE_ROOT:?DONE_DONE_EVIDENCE_ROOT must name the run folder}
rc=0
(cd "$root" && bash tests/jg-trunk-judge.test.sh) > "$ev/judge.log" 2>&1 || rc=$?
cat "$ev/judge.log"
printf '%s\n' '{"target": {"version": "core/trunk-verify/judge.sh at this head"}, "start": "a fixture home with a real git project, the real landing check, the real verify and the real alert tool", "steps": ["land a lane: the tip run keeps its verdict", "verify the same tree while it still agrees: no alert", "make the verify see a red: judge-split is raised once, then a judge that agrees replaces its verdict"], "result": "judge.log shows the verdict ledger rows and the one judge-split alert"}' > "$ev/steps.json"
exit "$rc"
