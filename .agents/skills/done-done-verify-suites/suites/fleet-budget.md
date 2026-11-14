# Fleet budget

Fleet budget: run `done-done run fleet-budget` (`bash journeys/fleet-budget.sh`, which runs `tests/jg-fleet-budget.test.sh` and writes its log and `steps.json` into the run's folder); it runs the real `core/lane-scale/fleet.sh budget` and `slot take` on a home with an own runner and a paid runner: heavy slots are the host's plus every usable runner's, a paid runner counts only while `core/runners/ledger.sh` allows paid minutes (daily cap default 0), and a run past the fleet's slots waits (screen: none).
