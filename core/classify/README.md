# classify

The status classifier is Go. `cmd/jg-classify` answers the status-line tests (captain-relevant,
terminal, paused, captain-held, paused-until) and reads status files (latest event, declared wait)
that the watcher, the away-mode daemon and the drain depend on. `bin/jg-classify.sh` builds it on
first use into the home's state directory; `bin/jg-classify-lib.sh` keeps the function names those
callers use and forwards each one.

## Port plan

The shell classifier and the wake library are one port in slices, each switching live only after a
parity replay against the shell it deletes, over this home's recorded events.

1. **This slice.** Latest-event read, captain relevance, declared waits, paused-until, the UTC
   time reader.
2. Line grammar for the folds: verb, note, key, stamp readers and the decision fold.
3. Presentation cursors and the incremental open-decisions scan.
4. The wake library: queue, locks, routing.

## Parity replay

The replay runs the shell reader from the base commit and the Go command over every recorded
status line, wake-queue row, bus event and inbox message of a home (about 132,000 lines), under the
default vocabulary and three override variants, plus the latest-event, previous-event and
declared-wait reads of every recorded status file. Each row is eight answers; any difference fails
the replay, and a control run with a corrupted Go side must fail it. `tests/jg-classify-go.test.sh`
keeps the interesting shapes as an end-to-end suite.
