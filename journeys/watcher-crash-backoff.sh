#!/usr/bin/env bash
# done-done journey: an idle home whose watcher keeps crashing on startup is re-armed after
# growing waits, a wake acknowledgement never reports success over a queue it could not bring up
# to date, and the wake engine rebuilds after the Go work folder its session exported was removed.
# The incident this pins: one home's watcher exited 1 every 1-2 seconds for hours because its
# stale engine could not rebuild, the drain kept presenting the last rendered rows, and every
# acknowledgement of them exited 0 having consumed nothing.
#
# Steps, all on the real commands in throwaway homes:
#   1. tests/jg-watch-silent-exit.test.sh: the real arm over a watcher that exits 1 waits 2s,
#      4s, then 8s (a shortened JG_WATCH_CRASH_BACKOFF) before each next fork;
#   2. tests/bus-direct.test.sh: an ack through a cutoff consumes exactly the rows at or below
#      it; with the engine unable to run, the drain and the ack both fail naming the cause
#      instead of presenting or "acknowledging" a stale row, and the row is gone once the engine
#      runs; the engine rebuilds with a removed GOTMPDIR;
#   3. tests/jg-guard-host.test.sh: the guard host, which shares the Go work-folder helper,
#      still loads a new rule from one file.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}/${RUN_ID:-watcher-crash-backoff}.log
{
  bash "$root/tests/jg-watch-silent-exit.test.sh" &&
  bash "$root/tests/bus-direct.test.sh" &&
  bash "$root/tests/jg-guard-host.test.sh"
} > "$out" 2>&1
