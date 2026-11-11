# Release record

Release record: run `done-done run release-record` (`bash journeys/release-record.sh`, which runs `tests/jg-machine-release.test.sh` and writes its log and `steps.json` into the run's folder); it lints the release table, reads a fixture release in each of its six states through the real observers (the ticket reads `delivering.joining` while the release is open, checking, red or ready), and runs the lander's release-stamp step over real commits to show each ticket named by a `Ticket` trailer gets `release_opened_at` once; it reads only generated fixtures (screen: none).
