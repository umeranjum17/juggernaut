# Home summary refresh at fleet scale

Run `done-done run home-summary-refresh-scale` (which runs `journeys/home-summary-refresh-scale.sh`: `tests/jg-home-summary-refresh-scale.test.sh`, then `tests/jg-home-summary-refresh-async.test.sh`); it writes the run log, the timing file and `steps.json` as evidence.
Over a fixture home of 6,400 backlog rows (about 26,000 markdown lines), 300 encoded captain holds and 600 saved contribution records, the real producer behind a direct `bin/jg-home-summary-refresh.sh` publishes a fresh `state/home-summary.json` and renders `state/whats-left.md` in under 20 seconds, a third of its 60-second deadline, and the listed holds carry their decoded reasons (screen: none).
