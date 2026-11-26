# Contributions check at fleet scale

Run `done-done run -- bash journeys/contributions-watcher.sh` to capture the registered watcher check over 900 final pull requests in an isolated home.
The journey runs `tests/jg-contributions.test.sh` against `bin/jg-contributions.sh` and `bin/jg-contributions.jq`, then captures whether the watcher cleared the failure streak and settled both new and existing owners without a forge read.
