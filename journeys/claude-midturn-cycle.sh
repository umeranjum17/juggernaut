#!/usr/bin/env bash
# done-done journey: a Claude lead with work under way gets a watcher cycle mid-turn, before any
# Stop, and a lead whose cycle is healthy gets no second one. tests/jg-turnend-guard.test.sh fires
# the real bin/jg-claude-stop-autoarm.sh --mid-turn the way the PostToolUse registration fires it,
# over a Squad Lead home with a real watcher; with JG_CLAUDE_LIVE_E2E=1 the journey also runs
# tests/jg-claude-midturn-arm-live-e2e.test.sh, one real Haiku turn under the tracked hooks, and
# keeps its transcript and probe result. This journey records those runs for review.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ev=${DONE_DONE_EVIDENCE_ROOT:?}
out=$ev/${RUN_ID:-run}.log
# The suite builds its own fixture homes; a caller's home must not leak into them.
unset JG_HOME JG_TASK_ID
(cd "$root" && bin/jg-test-run.sh tests/jg-turnend-guard.test.sh) > "$out" 2>&1
rc=$?
live=skipped
if [ "$rc" -eq 0 ] && [ "${JG_CLAUDE_LIVE_E2E:-}" = 1 ]; then
  (cd "$root" && JG_MIDTURN_LIVE_EVIDENCE="$ev/live" bin/jg-test-run.sh tests/jg-claude-midturn-arm-live-e2e.test.sh) > "$ev/live.log" 2>&1
  rc=$?
  live=ran
fi
cat "$out"
[ "$live" = skipped ] || cat "$ev/live.log"
cat > "$ev/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a Squad Lead home with one lane under way and no watcher; with the live run, a disposable clone of this checkout that is its own Squad Lead home under the tracked Claude hooks",
 "steps": ["fire the real auto-arm hook with --mid-turn from inside the session that holds the home's lock, with no Stop", "read the home's watcher through the same health check the turn-end guard uses", "fire it again over the healthy cycle and read the watcher and the cycle ledger", "live run ($live): start one real Haiku turn that runs true, then a probe that waits for a healthy watcher and watches it for 20 s, then ends"],
 "result": "the lead gets a live, identity-matched watcher with a fresh beacon within one firing and no Stop generation; the second firing leaves the same watcher and starts none; in the live turn the cycle is up before the turn ends and stays up while the turn runs on, with no arm command from the model"}
JSON
exit "$rc"
