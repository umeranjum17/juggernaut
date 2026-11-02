# classify

The status classifier is Go. `cmd/jg-classify` answers the status-line tests (captain-relevant,
terminal, paused, captain-held, paused-until) and reads status files (latest event, declared wait)
that the watcher, the away-mode daemon and the drain depend on. `bin/jg-classify.sh` builds it on
first use into the user's cache, keyed by the checkout, never into a home or the repository;
`bin/jg-classify-lib.sh` keeps the function names those callers use and forwards each one.

## Port plan

The shell classifier and the wake library are one port in slices, each switching live only after a
parity replay against the shell it deletes, over this home's recorded events.

1. Latest-event read, captain relevance, declared waits, paused-until, the UTC time reader.
2. Line grammar (verb, note, key, stamp readers) and the keyed-decision fold: open decisions, the
   current line, a key's closing verb, the fold's per-chunk step. The grammar contract is in
   `cmd/jg-classify/decide.go`.
3. **This slice.** The cursor-backed open-decisions fold: the per-file byte cursor and the running
   open set it persists, the two fleet-wide scans over it, the legacy cursor offset that seeds a
   presentation position, and the file facts they rest on (identity, size, modification time and a
   symlink-refusing span read). The cursor contract is in `cmd/jg-classify/cursor.go`.
4. Presentation cursors: the fleet manifest, its markers, retirement and the unread-surface scan.
5. The remaining status-span, activity and home-append-ledger reads, then the crew-absorb reads.
6. The wake library: queue, locks, routing.

## Parity replay

The replay runs the shell reader from the base commit and the Go command over every recorded
status line, wake-queue row, bus event and inbox message of a home (about 132,000 lines), under the
default vocabulary and override variants, plus the reads of every recorded status file: the
latest-event, previous-event and declared-wait reads, and for the decision fold the open set under
every task kind, the current line, own decisions, the needs-decision test, each key's closing verb
and the cursor-backed fold. Any difference fails the replay, and a control run with a corrupted Go
side must fail it. `tests/jg-classify-go.test.sh` keeps the interesting shapes as an end-to-end
suite.

For the cursor-backed fold the replay copies each recorded status file twice and runs both sides
over its own copy, so it compares what each one folds and the cursor it persists byte for byte
(over the identity class, since the two copies have different inodes): four successive calls per
file, including one that folds a fresh append and one bounded by a captured endpoint, plus the
legacy offset and both fleet-wide scans. `tests/jg-wake-drain-open-decisions-cursor.test.sh` drives
the real drain across growing logs and asserts the bounded read and each migration path.
