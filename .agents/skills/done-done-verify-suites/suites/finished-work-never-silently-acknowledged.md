# Finished work is never silently acknowledged

Source: `bin/jg-facts-lib.sh` (`jg_fact_next_step`, the one definition of a required next step), `bin/jg-wake-drain.sh`, `bin/jg-wake-status-lib.sh`, `core/next-step/next-step.sh`, `bin/jg-delivery-tick.sh`, `bin/jg-turnend-guard.sh` and `docs/turnend-guard.md`.
Run `done-done run finished-work-never-silently-acknowledged` (`bash tests/jg-finished-work.test.sh`, its log in the run's folder); the guard's own cases run under `done-done run jg-turnend-guard`.
Replay the case that started it on a synthetic home: two Recon lanes with done lines, their outcomes presented by the real drain, and two `alert-undelivered` pages raised by the real undelivered-alert check over refused captain messages.
Sweep them with `jg-wake-drain.sh --outcomes-before <now> --classified handled` and require the refusal (exit 3, nothing classified) that names both lanes, the step each owes and the `bin/jg-move.sh <ticket> relayed` that takes it.
Record one relay and require the refusal to name only the other lane, then record both and require the same sweep to classify both outcomes.
Sweep a home where nothing is owed (a ship done line, a lane with no record, a Recon that went back to work) and require the old classification.
Run `core/next-step/next-step.sh tick` on a Recon done 700 seconds ago and one done 100 seconds ago: require one `done-unhandled` P1 for the first, held by Main, naming the step, and none for the second.
Acknowledge that alert, drain and acknowledge its wake row, tick again, and require it still open; record the relay and require the next tick to resolve it with the relay as its proof.
Drive the real `bin/jg-recon-handoff.sh` through draft, assign, verdict with gaps, revise, a second critic and a clear verdict, and require `bin/jg-machine-guard.sh fact next-step` to name assign, verdict, revise and relay for the right lane and phase, and none once each move is made.
`tests/jg-turnend-guard.test.sh` drives the real guard over a primary with a healthy watcher: it lets the turn end before the alert exists, blocks it while the alert is open (acknowledged or not), lifts at once when the relay is recorded, and ends the refusal after the session's budget with a notice naming the lane.
