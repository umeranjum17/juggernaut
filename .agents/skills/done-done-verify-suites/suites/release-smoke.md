# Release smoke

Release smoke: run `bin/jg-release-smoke.sh` (and `bash tests/jg-release-smoke.test.sh` for its pass and over-budget cases); it replays a design lane, a multi-PR lane and a signature lookup through the real merge path in a throwaway home and ends `release smoke: PASS lanes=3`.
