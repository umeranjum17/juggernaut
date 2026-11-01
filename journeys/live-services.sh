#!/usr/bin/env bash
# A release is live only when its services run: the fake-probe test, then the real check on this machine.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${DONE_DONE_RUN_ID:-run}.log
{
  bash "$root/tests/jg-live-claim.test.sh" || exit 1
  echo "== real check on this machine (a down service is reported, not hidden)"
  bash "$root/bin/jg-live-services.sh"; echo "exit $?"
} > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "fake service probes with every required service up, then the real machine",
 "steps": ["take two services down and run bin/jg-live-services.sh", "claim a recorded release live and see it downgraded", "bring them up and see the claim stand", "run the real check here"],
 "result": "a down service is named and a live claim is refused; with all up it stands; the real run prints one line per service and the not-in-design services"}
JSON
exit "$rc"
