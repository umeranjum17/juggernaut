#!/usr/bin/env bash
# done-done journey: run the browser sweep behavior test (fake process list, real processes and profile
# folders in a disposable folder) and write its transcript into the evidence folder.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${DONE_DONE_RUN_ID:-${RUN_ID:-browser-sweep}}.log
bash "$REPO/tests/jg-browser-sweep.test.sh" >"$LOG" 2>&1
st=$?
grep -q '^not ok' "$LOG" && st=1
[ "$(grep -c '^ok - ' "$LOG")" -ge 7 ] || st=1
cat "$LOG"
cat >"$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut bin/jg-browser-sweep.sh at this commit"},
 "start":"a fake process list with old and young bridges and puppeteer browsers, a real old browser process, and stopped and orphan profile folders",
 "steps":["dry-run the sweep and check nothing is stopped","widen with --hours 0 and narrow with --no-bridges","apply and check the old browser stops","check the before and after counts and the profile folders"],
 "result":"the dry run stops nothing; apply stops only the old matching browser, reports the counts before and after, and removes the stopped and orphan profile folders; seven checks pass"}
J
exit "$st"
