#!/usr/bin/env bash
# done-done journey: a journey whose command clears an env var runs, because done-done's preflight reads that command.
# The behavior test (tests/jg-done-yaml-env-unset.test.sh) runs every shipped env-starting journey through done-done's own run.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-done-yaml-env-unset.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped .done-done.yaml of the repository and a scratch repo holding a copy of it",
 "steps": ["list every journey whose command starts an env", "run each one through done-done run in the scratch repo with a stand-in bash", "read done-done's answer for a refusal as command not found"],
 "result": "done-done runs every one of those journeys and refuses none as a command not found"}
JSON
exit "$rc"
