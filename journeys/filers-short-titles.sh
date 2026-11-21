#!/usr/bin/env bash
# done-done journey: a ticket a script files by itself reads as plain words, with the detail in its body.
# It runs the suites of the scripts that file a ticket by themselves (post-merge CI, trunk flaky and shard rows, red-CI ticket,
# report approval, captain-ask note); each suite checks the stored title against the title rule of tests/title-rule-lib.sh.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/filers-short-titles.txt
: > "$LOG"
cd "$REPO" || exit 1
status=0
for suite in tests/jg-post-merge-ci-main.test.sh tests/jg-trunk-gate.test.sh tests/jg-trunk-shard-ticket.test.sh \
  core/merge-on-green/tests/red-ci-ticket.test.sh tests/jg-inbox.test.sh; do
  printf '== %s\n' "$suite" | tee -a "$LOG"
  if bash "$suite" >>"$LOG" 2>&1; then echo "ok: $suite" | tee -a "$LOG"; else echo "FAIL: $suite" | tee -a "$LOG"; status=1; fi
done
printf '== core/report-actions/tests/test_report_actions.py\n' | tee -a "$LOG"
if python3 -I core/report-actions/tests/test_report_actions.py >>"$LOG" 2>&1; then echo "ok: report-actions" | tee -a "$LOG"; else echo "FAIL: report-actions" | tee -a "$LOG"; status=1; fi
exit "$status"
