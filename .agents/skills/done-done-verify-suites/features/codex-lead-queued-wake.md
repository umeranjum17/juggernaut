# Codex lead queued wakes and quiet checkpoints

Run `done-done run codex-lead-queued-wake` from the repository root.
The portable journey drives the real watcher and daemon in disposable marked homes and a private tmux server with a synthetic receiver.
It completes the initial idle scan before appending an older batch row and an urgent inbox wake.
It requires the urgent operational record within 60 seconds, once, with its key present once in the record body.
A batch-only interval must submit nothing.
After delivery, repeating the same event must be producer-classed batch and produce no additional submission during 35 seconds.
The ordinary queue reader retains that row while the urgent-only reader excludes it.
PID-matched startup logs check the non-lead default, the explicit override and the lead default.
A separate empty home runs the actual one-second foreground checkpoint and requires exit 0 and `phase=quiet`.
Hard-bound behavior remains covered by `tests/jg-supervision-lead.test.sh`.

The queue delivery owner is `own_queue_resurface` in `bin/jg-watch.sh`.
Its lead caller in `idle_wait` observes urgent work at the ordinary poll cadence while retaining the longer idle scan interval.
The daemon remains the owner of classification and acknowledgement.
The real Codex proof is separate from this synthetic regression.

Captures include `steps.json`, `timing.json`, `receiver.log`, `record.body.txt`, the actual daemon and watcher logs, checkpoint output/status and cleanup outcomes.

Sources: `journeys/codex-lead-queued-wake.mjs`, `bin/jg-watch.sh`, `core/bus/cmd/jg-bus/watcher.go`, `bin/jg-watch-checkpoint.sh`, `bin/jg-supervise-daemon.sh`, `docs/configuration.md`, `docs/supervision-protocols/codex.md`, `.done-done.yaml`, `.agents/skills/done-done-verify-suites/features/README.md`, `.agents/skills/done-done-verify-suites/suites/codex-lead-wake.md`.
