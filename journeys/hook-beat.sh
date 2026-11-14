#!/usr/bin/env bash
# done-done journey: a real bin/jg-spawn.sh of a Claude lane wires the hook dispatcher (bin/jg-hook.sh, core/hooks/), and each wired
# hook command, run as Claude Code runs it, appends a timed beat line to state/beats/<task> through bin/jg-beat.sh. The transcript goes
# into the evidence folder.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-hook-beat}.log
st=0
{
  echo "== spawn a Claude lane, run each wired hook, read the beat record"
  bash "$REPO/tests/jg-hook-beat.test.sh" 2>&1
} >"$LOG" 2>&1
grep -q '^FAIL\|^not ok' "$LOG" && st=1
[ "$(grep -c '^ok - T' "$LOG")" -ge 4 ] || st=1
cat "$LOG"
cat >"$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut bin/jg-hook.sh, bin/jg-beat.sh and core/hooks/ at this commit"},
 "start":"a fixture home and project, and a Claude lane spawned into its own isolated copy",
 "steps":["read the hook wiring the spawn wrote for the lane","run the wired hook for turn start, two tool batches and turn end","run the wired hook for an API error with a type and with none, then session end","run a wired hook against a missing state folder"],
 "result":"each event adds one timed line to the beat record in order; an API error writes its type, or unknown; a failing hook exits 0 and writes nothing"}
J
exit "$st"
