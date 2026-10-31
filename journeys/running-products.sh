#!/usr/bin/env bash
# done-done journey: a home lists two services, one auto and one manual, and both are behind the release.
# bin/jg-running-products.sh names both versions, restarts only the auto unit, and reports the manual one again.
# tests/jg-running-products.test.sh is that journey: it drives the real script in a throwaway home with a stub
# systemctl, so its transcript is the evidence and its exit is the verdict.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
bash "$REPO/tests/jg-running-products.test.sh" >"$OUT/transcript.txt" 2>&1
status=$?
cat "$OUT/transcript.txt"
cat >"$OUT/steps.json" <<'JSON'
{"target":{"version":"juggernaut bin/jg-running-products.sh at this commit"},
 "start":"a throwaway home whose config lists one auto and one manual service, both behind the release",
 "steps":["run check with both services behind","run refresh","read the systemctl calls it made","run check again once the auto service is current"],
 "result":"both services are named with their running and wanted versions, only the auto unit restarts, once, and the manual service is reported again and left alone"}
JSON
exit "$status"
