#!/usr/bin/env bash
# The merge gate's rules as Rego and JSON (policy/gate/), proved on the real gate scripts: the policy's own
# contract tests, then 40 pull requests through the real jg-checks-lint.sh and the guard host's `eval` door,
# and recorded checks-gate.log rows through the owner-rules gate's fact gathering, each held to the verdict the
# shell rules gave before they moved to policy.
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
[ "$fails" -eq 0 ] || { printf '%s check(s) failed\n' "$fails" >&2; exit 1; }
printf 'merge-gate-policy: Rego decides, the lint and the gate gather facts, recorded decisions reproduced\n'
