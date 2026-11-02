#!/usr/bin/env bash
# E2E: the owner-rules gate's checks-lint rule (policy/gate/lint_row.rego) gives the verdicts the shell rule it
# replaced gave on recorded decisions. checks-gate-recorded.log holds real rows of a home's data/checks-gate.log
# (pass, fail and card rows, a fail taken back by a later pass, local-merge report rows) and
# checks-gate-recorded.queries holds, per line, `pr  head  task  verdict`: the verdict the awk rule returned on
# that log. Every query goes through the same fact-gathering as the gate and the one policy evaluator.
# Usage: core/owner-rules/tests/lint-row-recorded.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$here/../../.." && pwd -P)
# shellcheck source=lib/policy-test-env.sh
. "$ROOT/core/lib/policy-test-env.sh"
fails=0 n=0
while IFS=$'\t' read -r pr head task want; do
  n=$((n + 1))
  got=refuse
  if jq -Rn --arg pr "$pr" --arg head "$head" --arg task "$task" \
    '{pr: $pr, head: $head, task: $task, rows: [inputs | split("\t") | select(length >= 4) | {src: .[1], head: .[2], verdict: .[3]}]}' \
    "$here/checks-gate-recorded.log" | "$ROOT/bin/jg-guard-host.sh" eval gate.lint_row | jq -e '.ok' >/dev/null; then got=pass; fi
  if [ "$got" != "$want" ]; then
    printf 'FAIL: pr=%s head=%s task=%s want=%s got=%s\n' "$pr" "$head" "$task" "$want" "$got"
    fails=$((fails + 1))
  fi
done < "$here/checks-gate-recorded.queries"
[ "$n" -gt 0 ] || { echo "FAIL: no recorded queries"; exit 1; }
[ "$fails" -eq 0 ] && printf 'PASS: %s recorded decisions reproduced by the policy\n' "$n" && exit 0
printf 'FAIL: %s of %s recorded decisions differ\n' "$fails" "$n"
exit 1
