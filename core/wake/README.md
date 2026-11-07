# wake

The wake library's decisions are being ported to Go in slices, each switched live only after a parity
replay against the shell it deletes. `bin/jg-wake-core.sh` builds `cmd/jg-wake-core` on first use into
the user's cache, keyed by the checkout, the way `bin/jg-classify.sh` builds the status classifier;
`bin/jg-wake-lib.sh` keeps the function names its callers use and forwards each one, so a slice
deletes shell rather than adding a second owner beside it.

## Port plan

1. **The queue read model.** What a queued row is (`jg_wake_print_deduped`), the keys queued for a
   kind (`jg_wake_queued_keys`), which sequence numbers are still queued (`jg_wake_rows_queued`), how
   many rows an actor could act on (`jg_wake_actor_pending_count`), and whether a branch grant's row
   snapshot is well formed (`jg_wake_grant_rows_valid`). About 55 shell lines were deleted; the
   library keeps the function names, the queue lock around the key read, and the "a broken reader is
   one pending row" rule.
2. **Wake urgency routing.** The rule files in force and their priority, the shell pattern grammar,
   the `@parked`, `@restart-pass`, `@queue-quiet`, `@watcher-alive`, `@gap-long` (a heartbeat gap open at least `set gap-wake-seconds`) `@lead-restarted` (the lead restarted within the restart pass or `set lead-restart-grace-seconds`) `@ship-pr` (the key is a task whose record is a ship, kind absent or `ship`), and `@merge-owned` (the newest status line is a ship's PR-ready `done` line, the task record names that PR and its head, `yolo=on` or `merge=approved` and not `merge=manual` gives `core/merge-on-green` the merge, and the watcher has not already spent its one attempt on that head, which `data/jg-merge-on-green/<task>.head` records) conditions, the re-alert dedupe
   on an event's own identity, and the hourly silence cap. `jg_wake_route_class`, `jg_wake_routing_files`,
   `_jg_wake_rule_set` and `_jg_wake_realert_record` stay as the names callers use, and
   `jg_wake_append_locked` asks the command once for the class it acts on. Where the command cannot
   run, an event is `now`, never hidden.
3. The queue writers: `jg_wake_queue_prune_task` and the `jg_wake_withdraw` bookkeeping that retires
   rows on the bus.
4. Presentation: `jg_wake_annotation_manifest`, `jg_wake_print_annotations`, `jg_wake_unread_events`,
   and the open-decisions sections the drain prints.
5. Signal-seen and status-commit bookkeeping (`jg_wake_signal_*`, `jg_wake_status_*`).
6. Locks, recovery markers and the auto-arm ledger (`jg_lock_*`, `_jg_recovery_marker_*`,
   `jg_autoarm_*`).
7. Process and watcher health helpers (`jg_pid_*`, `jg_watcher_*`, the supervision verdicts).
8. The rest of `bin/jg-watch.sh`, then deleting it and the library.

## Parity replay

The queue replay runs the library's own entry points from the base commit's shell and from the port
over the same rows: every queue row of the 123 events recorded on a real `JG_WAKE` stream
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

The routing replay runs `jg_wake_route_class` and `jg_wake_append_locked` from the base commit's shell
and from the port over the same cases: every raise of the 241 events recorded on a real `JG_WAKE`
stream plus the shapes that stream lacks, in 27 scenarios (the default rules, 14 generated rule
files covering the pattern grammar, parked homes, restart passes and queue states, a rule file that
matches nothing with and without the shared defaults behind it, a missing rule file, an override
file). A difference in any class fails the replay; a control run with one
corrupted answer must fail it. `tests/fixtures/wake-recorded/route-classes.tsv` keeps the classes
the shell gave the distinct recorded events, and `tests/jg-wake-core.test.sh` checks the port
against them. `tests/jg-wake-route.test.sh` drives the classes through the library's own entry
points, so the wiring the watcher and the producers use is covered too.

Two differences are deliberate. `queue-quiet` routes every queued row, so a rule that names a queued
row's own kind and key made the shell recurse until it died; the port stops after eight levels and
treats the queue as not quiet. A non-numeric stamp in `state/.squad-lead-restart-pass` made the
shell abort under `set -u`; the port treats the line as no match.

## The wake schedule

`defaults/wake-routing` decides who is woken at once. The `now` rows are limited to a captain answer
(`inbox:*`, `mail:*`, a decision or blocked status line), a red gate (a `failed` check), a host alarm
(`host-memory`, `delete-guard`, model outage, supervision-host return, startup and sentinel checks), a
worker stuck past its ladder (`stale`, `*-stall`, `*-owner`, `*-escalation`, `waiting-timer-*`), and a
finished deliverable (a ready or PR-ready status line). The catch-all is `batch`, so an unknown event
waits instead of waking, and is never dropped.

`schedule.go` adds two decisions, both read from the rule file. `jg_wake_digest_due mark` answers the
batched digest: a window opens with the first routine row, and one digest wake naming the count is due
when `set digest-count` (default 5) routine rows have queued since the last release or `set digest-minutes`
(default 15) has passed, whichever comes first, and none is sent when no routine row waits. `silent@fleet-unchanged heartbeat`
keeps an away-mode heartbeat silent while the sorted status, meta and hold file names and sizes match the
fingerprint recorded by the last heartbeat that woke. A `done` carrying a key already closes that key's
wait (`tests/jg-wake-batching.test.sh`), so an answered key never re-pings. A pause that names its future
event with `until <time>` is a planned wait: its status line, its recheck before that time and its timer
ride the digest, while a `blocked` wait with no clearing condition and a pause past its declared time
keep waking.

`bin/jg-context-bound.py rates <transcript>...` reports wakes per hour from session records, so the
rate is measured the same way before and after. `tests/jg-wake-schedule.test.sh` proves the journeys.
