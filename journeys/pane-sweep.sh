#!/usr/bin/env bash
# done-done journey: drive the real core/pane-sweep/sweep.sh in a real isolated Herdr lab session, through
# tests/jg-pane-sweep.test.sh, and write the transcript into the evidence folder (screen: none).
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${DONE_DONE_RUN_ID:-${RUN_ID:-pane-sweep}}.log
st=0
printf 'journey pane-sweep at commit %s\n' "$(git -C "$REPO" rev-parse HEAD)" >"$LOG"
bash "$REPO/tests/jg-pane-sweep.test.sh" >>"$LOG" 2>&1 || st=1
grep -q '^not ok' "$LOG" && st=1
[ "$(grep -c '^ok - ' "$LOG")" -ge 6 ] || st=1
cat "$LOG"
cat >"$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut core/pane-sweep/sweep.sh at this commit"},
 "start":"a real Herdr lab session with the home's own workspace holding an old bare shell no record names, a fresh bare shell, a recorded pane and a pane running a process, plus a bare shell in another workspace",
 "steps":["run the pane sweep on the home","run the pane sweep a second time"],
 "result":"only the old unrecorded bare shell is closed, and its line names the task the spawn map says started it; every other pane stays and the second sweep prints nothing"}
J
exit "$st"
