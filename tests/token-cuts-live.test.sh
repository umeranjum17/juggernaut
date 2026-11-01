#!/usr/bin/env bash
# The token cuts and the escalation rules, driven as the journeys the merge judge reads:
# journeys/token-cuts-live.sh (wake turns before and after, settled types, cap, digest)
# and journeys/escalation-rules-live.sh (the live escalation tick and the real queue).
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(jg_test_tmproot token-cuts-live)
for journey in token-cuts-live escalation-rules-live; do
  mkdir -p "$T/$journey"
  DONE_DONE_EVIDENCE_ROOT=$T/$journey bash "$ROOT/journeys/$journey.sh" >"$T/$journey.log" 2>&1 \
    || { tail -20 "$T/$journey.log"; fail "journey $journey failed"; }
  pass "journey $journey passes"
done
