# wake

The wake library's decisions are being ported to Go in slices, each switched live only after a parity
replay against the shell it deletes. `bin/jg-wake-core.sh` builds `cmd/jg-wake-core` on first use into
the user's cache, keyed by the checkout, the way `bin/jg-classify.sh` builds the status classifier;
`bin/jg-wake-lib.sh` keeps the function names its callers use and forwards each one, so a slice
deletes shell rather than adding a second owner beside it.

Wake urgency routing is not part of this port; it keeps its own change.

## Port plan

1. **This slice.** The queue read model, from `bin/jg-wake-lib.sh`: what a queued row is
   (`jg_wake_print_deduped`), the keys queued for a kind (`jg_wake_queued_keys`), which sequence
   numbers are still queued (`jg_wake_rows_queued`), how many rows an actor could act on
   (`jg_wake_actor_pending_count`), and whether a branch grant's row snapshot is well formed
   (`jg_wake_grant_rows_valid`). About 55 shell lines are deleted; the library keeps the function
   names, the queue lock around the key read, and the "a broken reader is one pending row" rule.
2. The queue writers: `jg_wake_queue_prune_task` and the `jg_wake_withdraw` bookkeeping that retires
   rows on the bus.
3. Presentation: `jg_wake_annotation_manifest`, `jg_wake_print_annotations`, `jg_wake_unread_events`,
   and the open-decisions sections the drain prints.
4. Signal-seen and status-commit bookkeeping (`jg_wake_signal_*`, `jg_wake_status_*`).
5. Locks, recovery markers and the auto-arm ledger (`jg_lock_*`, `_jg_recovery_marker_*`,
   `jg_autoarm_*`).
6. Process and watcher health helpers (`jg_pid_*`, `jg_watcher_*`, the supervision verdicts).
7. The rest of `bin/jg-watch.sh`, then deleting it and the library.

## Parity replay

The replay runs the library's own entry points from the base commit's shell and from the port over
the same rows: every queue row of the 123 events recorded on a real `JG_WAKE` stream
(`tests/fixtures/wake-recorded/queue-rows.tsv`) plus the shapes that stream lacks - a repeated
kind and key, heartbeats with moving keys, a payload holding a tab, a line too short to be a row, a
row whose sequence is not a number - and a live branch grant built on the test's own process.

`tests/jg-wake-core.test.sh --replay <git-ref>` replays both sides and requires identical stdout and
exit status for all 23 answers, then requires a corrupted control run to differ.
`--replay <git-ref> --record` writes the shell's answers to
`tests/fixtures/wake-recorded/queue-reads.tsv`, which every ordinary run compares the Go answers
with so CI needs no base checkout. The suite also asserts the shapes no replay reaches on their own,
so a regenerated pin cannot bless a wrong answer.

Two differences are deliberate. The shell reader answered a queue it could not open with awk's own
message and exit 2; the command answers with its own message and the same exit 2, because stderr is
not part of the contract. A home with no Go toolchain has no reader: the dispatcher says so and
exits 2, so a broken reader is never read as an empty queue.
