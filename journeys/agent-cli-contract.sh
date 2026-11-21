#!/usr/bin/env bash
# Drive the public CLI and the inventory's real script parsers in isolated homes.
set -euo pipefail

bash bin/jg-lint.sh bin/jg core/agent-cli/dispatch.sh core/agent-cli/tests/contract.test.sh \
  core/agent-cli/tests/forms.test.sh journeys/agent-cli-contract.sh > "$DONE_DONE_EVIDENCE_ROOT/lint.log" 2>&1 \
  || { tail -n 25 "$DONE_DONE_EVIDENCE_ROOT/lint.log" >&2; exit 1; }
for suite in inventory forms contract e6land2; do
  log="$DONE_DONE_EVIDENCE_ROOT/$suite.log"
  bash "core/agent-cli/tests/$suite.test.sh" > "$log" 2>&1 || { tail -n 25 "$log" >&2; exit 1; }
done
if [ "$#" -gt 0 ]; then
  bash bin/jg-test-run.sh --changed --base "$1" --json "$DONE_DONE_EVIDENCE_ROOT/changed-tests.json" \
    > "$DONE_DONE_EVIDENCE_ROOT/changed-tests.log" 2>&1 \
    || { tail -n 25 "$DONE_DONE_EVIDENCE_ROOT/changed-tests.log" >&2; exit 1; }
fi
