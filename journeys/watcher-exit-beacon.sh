#!/usr/bin/env bash
# done-done journey: the watcher liveness beacon, read the way a lead's supervision check reads
# it. A live watcher stays supervised through a due-check sweep longer than the stale grace - the
# false "the watcher beacon is Ns old and no turn is running" alarm that cost main a turn - a
# killed watcher reads as unsupervised inside the grace window, and an actionable exit leaves the
# home supervised once the hand-off stamp ages out. The proof itself lives in
# tests/jg-watch-beacon.test.sh, which arms the real watcher and owns these cycles; this journey
# records that run for review.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
lab=$(mktemp -d "${TMPDIR:-/tmp}/jg-continuation-proof.XXXXXX") || exit 1
trap 'rm -rf -- "$lab"' EXIT
mkdir -p "$lab/user" "$lab/config" "$lab/data" "$lab/cache" "$lab/tmp"
export HOME="$lab/user" XDG_CONFIG_HOME="$lab/config" XDG_DATA_HOME="$lab/data" XDG_CACHE_HOME="$lab/cache" TMPDIR="$lab/tmp"
{
  bash "$root/tests/jg-watch-beacon.test.sh" &&
  bash "$root/tests/jg-trunk-check.test.sh" &&
  bash "$root/core/wait-timers/tests/jg-wait-timers.test.sh"
} > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "throwaway homes on the file wake queue, including a stale first scan and a blocked explicit binary: one registers four slow checks, so every due-check sweep runs twice as long as a 4 s stale grace, and one has a task signal waiting behind a 10 minute old beacon",
 "steps": ["run the real outer watcher with an urgent queued wake and an eligible ready/PASS lane; observe dispatch before exit and its detached exact-head landing", "interrupt a recovering first scan after one completed unit, restart it and prove the complete scan", "drain and acknowledge three blocker re-alerts without handling, then correct its synthetic binary and retry while preserving an unrelated call", "arm the real watcher in the sweep home and sample the supervision read across a whole sweep", "kill the watcher on a fresh beacon and sample the supervision read until it reports unsupervised", "arm the real watcher in the signal home and let it end its cycle on the task signal", "age the hand-off stamp out and take the supervision read"],
 "result": "the outer watcher dispatches ready/PASS before the urgent wake exits and the detached check lands it without going live; stale first-scan progress is recognised, interrupted recovery completes, and the blocker re-fires until a successful owner retry; the live sweep stayed supervised, the killed watcher was reported unsupervised inside the grace window, and the actionable exit left the home supervised"}
JSON
exit "$rc"
