#!/usr/bin/env bash
# done-done journey: the merge gate's rules as Rego and JSON (policy/gate/), proved on the real gate scripts.
# The policy's own contract tests run first; then 40 pull requests go through the real jg-checks-lint.sh and
# the guard host's `eval` door, and recorded checks-gate.log rows go through the owner-rules gate's fact
# gathering, each against the verdict the shell rules gave before they moved to policy.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
cd "$REPO" || exit 1
fails=0
log=$OUT/merge-gate-policy.log
{
  opa version | head -n 1
  opa test policy || fails=$((fails + 1))
  bash core/merge-on-green/tests/checks-lint-cases.test.sh || fails=$((fails + 1))
  bash core/owner-rules/tests/lint-row-recorded.test.sh || fails=$((fails + 1))
  echo "journey failures: $fails"
} > "$log" 2>&1
cat "$log"
[ "$fails" -eq 0 ]
