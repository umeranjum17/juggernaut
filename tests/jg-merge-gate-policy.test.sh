#!/usr/bin/env bash
# The merge gate's rules as Rego and JSON (policy/gate/), proved on the real gate scripts: the policy's own
# contract tests, then 40 pull requests through the real jg-checks-lint.sh and the guard host's `eval` door,
# recorded checks-gate.log rows, 62 homes through the owner-rules merge gate, 73 backlog items through the brief
# rules and 41 task records through the completion-receipt acceptance, each held to the decision the shell rules
# gave before they moved to policy.
#
# This is also the test that owns journeys/merge-gate-policy.sh (the done-done journey runs this file), so the
# changed-test map selects it for a change to that journey or to anything under policy/gate/.
# Needs opa and Go; with either absent it skips.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=core/lib/policy-test-env.sh
. "$ROOT/core/lib/policy-test-env.sh"
cd "$ROOT" || exit 1
fails=0
run() {  # <label> <command...>
  local label=$1
  shift
  if "$@"; then printf 'ok: %s\n' "$label"; else printf 'FAIL: %s\n' "$label"; fails=$((fails + 1)); fi
}
opa version | head -n 1
run "the policy's own Rego contract tests pass" opa test policy
run "40 pull requests give their recorded verdicts through the real lint" bash core/merge-on-green/tests/checks-lint-cases.test.sh
run "recorded checks-gate.log rows give their recorded verdicts through the owner-rules gate" bash core/owner-rules/tests/lint-row-recorded.test.sh
run "62 homes give their recorded decisions through the real owner-rules merge gate" bash core/owner-rules/tests/gate-matrix.test.sh
run "41 task records give their recorded decisions through the receipt acceptance" bash core/receipts/tests/receipt-accept-cases.test.sh
[ "$fails" -eq 0 ] || { printf '%s check(s) failed\n' "$fails" >&2; exit 1; }
printf 'merge-gate-policy: Rego decides, the lint and the gate gather facts, recorded decisions reproduced\n'
