# wake

The wake library's decisions are being ported to Go in slices, each switched live only after a parity
replay against the shell it deletes. `bin/jg-wake-core.sh` builds `cmd/jg-wake-core` on first use into
the home's state directory, the way the teardown and guard-host cores are built.

## Port plan

1. **This slice.** Wake urgency routing, from `bin/jg-wake-lib.sh`: the rule files reader (a home's
   `config/wake-routing` first, then `defaults/wake-routing`, or `JG_WAKE_ROUTING` alone) and its
   shell-pattern matching, the `@parked`, `@restart-pass`, `@queue-quiet` and `@watcher-alive`
   conditions, the re-alert dedupe that uses a status row's newest line as its identity, and the
   hourly silence cap that `jg_wake_append_locked` applies. About 140 shell lines are deleted; the
   library keeps `jg_wake_route_class`, `jg_wake_routing_files` and the append function as callers
   of the command. Where the command cannot run, an event is `now`.
2. The queue and withdraw readers (`jg_wake_queued_keys`, `jg_wake_withdraw`, the deduped print and
   annotations) on top of the bus consumer from the watcher port.
3. The signal-seen and status-commit bookkeeping (`jg_wake_signal_*`, `jg_wake_status_*`).
4. Locks, recovery markers and the auto-arm ledger (`jg_lock_*`, `_jg_recovery_marker_*`,
   `jg_autoarm_*`).
5. Process and watcher health helpers (`jg_pid_*`, `jg_watcher_*`, the supervision verdicts).
6. The rest of `bin/jg-watch.sh`, then deleting it and the library.

## Parity replay

The replay runs `jg_wake_route_class` and `jg_wake_append_locked` from the base commit's shell and
from the port over the same cases: every raise of the 241 events recorded on a real `JG_WAKE`
stream plus the shapes that stream lacks, in 24 scenarios (the default rules, 13 generated rule
files covering the pattern grammar, parked homes, restart passes and queue states, a missing rule
file, an override file). A difference in any class fails the replay; a control run with one
corrupted answer must fail it. `tests/fixtures/wake-recorded/route-classes.tsv` keeps the classes
the shell gave the distinct recorded events, and `tests/jg-wake-core.test.sh` checks the port
against them.

The rule files are read the way the library concatenates them, so a final line with no newline is
read like any other, and a home's `set` value wins over the shared file's.

One difference is deliberate. `queue-quiet` routes every queued row, so a rule that names a queued
row's own kind and key made the shell recurse until it died; the port stops after eight levels and
treats the queue as not quiet. A non-numeric stamp in `state/.squad-lead-restart-pass` made the
shell abort under `set -u`; the port treats the line as no match.
