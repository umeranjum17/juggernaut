#!/usr/bin/env bash
# Sealed done-done proof for stall-action (screen: none): the whole fixture-home journey, with a step record.
# Usage: done-done run -- bash core/stall-action/run-proof.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
evidence=${DONE_DONE_EVIDENCE_ROOT:?run this under done-done run}
version=$(git -C "$here" rev-parse --short=9 HEAD 2>/dev/null || echo unknown)
bash "$here/tests/stall-action.test.sh" > /dev/null   # the test writes stall-action.log into the evidence folder itself
cat > "$evidence/steps.json" <<JSON
{"target": {"version": "$version"},
 "start": "a fixture home with a worker, a lead and tasks that are paused, finished, exited, idle or unpolled, each with the watcher's pane records",
 "steps": ["a worker whose pane output stayed the same for 6 minutes is swept: one interrupt and one re-ring are recorded and nothing is printed", "the same sweep again: nothing happens for that hash", "a paused, finished, exited, idle, unpolled or changing task is swept: nothing happens", "a lead is acted on at 10 minutes and not at 7; a failing interrupt is tried twice and then given up", "an idle worker and an idle lead each with a real hung sleep 1000 command in their worktree are interrupted once and re-rung once naming the background command; the same idle agents with nothing running, a changing pane and a declared pause are untouched"],
 "result": "a stalled worker or lead is interrupted and re-rung once per hash with no model turn, and every task that is not stalled is left alone"}
JSON
