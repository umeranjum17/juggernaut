# Cold status-span classification

Cold status-span classification: run `done-done run status-cold-scan` (`bash journeys/status-cold-scan.sh`); the shared reader used by the watcher and drain classifies 20,000 historical progress lines plus a live blocker in one Go call, retains the blocker and endpoint, preserves all status bytes, and advances no presentation cursor.
Inspect the run-owned `cold-span.txt`, `timing.log` and `result.log`; `bash tests/jg-classify-go.test.sh` and `bash tests/jg-wake-drain-open-decisions-cursor.test.sh` cover event grammar and incremental drain integration (screen: none).
