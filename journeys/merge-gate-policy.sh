#!/usr/bin/env bash
# The merge gate's rules as Rego and JSON: the policy's contract tests, 40 pull requests through the real lint and recorded gate-log rows through the owner-rules gate, each against the verdict the shell rules gave before they moved to policy.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/merge-gate-policy.log
bash "$root/tests/jg-merge-gate-policy.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
exit "$rc"
