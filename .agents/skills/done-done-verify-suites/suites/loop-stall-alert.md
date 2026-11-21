# Loop stall alert

Loop stall alert: run `done-done run -- bash tests/jg-loop-stall.test.sh` (it writes `loop-stall.log` into `$DONE_DONE_EVIDENCE_ROOT`).
It proves `core/loop-stall/loop-stall.sh tick` over a real Beads home: a Blitz plan with a startable slice and nothing in flight is quiet at 599 seconds and raises one `fleet-blocked` P1 at 601 seconds, an acknowledgement and later ticks leave it open, a slice started closes it with `source:progress-ready-work-gone` as proof, a slice landed with another still ready restarts the clock, and an unreadable plan home changes nothing.
It proves the same clock and alert for a Goal whose step waits (read through `core/goal-loop/goal-loop.sh state`), closed only when the step is taken, and no alert for a Goal stopped for its owner (screen: none).
