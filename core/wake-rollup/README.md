# wake-rollup

Main gets one digest per home per 10 minutes; only the P0 classes ring at once (H35).

`bin/jg-wake-lib.sh` asks `rollup.sh hold` for every event before it queues it. A non-P0 event of a Squad Lead's status stream
is held; the watcher check `rollup.sh check <jg-home>` (installed by `wiring.sh`, removed by `unwiring.sh`) prints one
`wake-rollup: <home>: N events in 10 min (class counts)` line per home once its oldest held event is 10 minutes old. P0 (needs-decision,
failed, blocked, security, stale, any non-lead stream) rings at once. `config/wake-rollup-off` restores today's wakes.
`rollup.sh board` writes `data/wake-rollup/wakes-per-day.tsv` (day, rang, held, digests), Main's wakes a day.

Proof: `bash core/wake-rollup/tests/wake-rollup.test.sh` drives `jg_wake_append` with 100 events from one home.

## Prior art

Prometheus Alertmanager (Apache-2.0) `group_wait`/`group_interval`: group by home, one notification per window; the shape only,
no code used. The in-repo `core/escalation-optimize` coalesce rule is the home-local form this extends across homes.
