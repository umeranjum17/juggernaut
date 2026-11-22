# Swarm blocked lanes

Run `done-done run -- bash journeys/swarm-blocked-lanes.sh` to drive the scheduled lane read in `bin/jg-swarm-check.sh`, its status fold in `core/classify/cmd/jg-classify/decide.go` and the steer claim in `bin/jg-delivery.sh`.
The journey checks live running and waiting lanes, queued and landed slices, and an overdue dependency pause during a partial stall.
It checks that an overdue lane rings Main once, clears on resolution, and that a claimed steer writes one action per named lane in the lead home, with the transcript in `swarm-blocked-lanes.log`.
It also runs the repository lint and the existing delivery and Go-entry regressions.
