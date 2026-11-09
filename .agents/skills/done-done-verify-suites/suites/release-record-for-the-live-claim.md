# Release record for the live claim

Release record for the live claim: run `done-done run -- bash tests/jg-release-tag.test.sh`; the real `bin/jg-release-tag.sh` and `bin/jg-live-claim.sh` over a recording forge and a fixture home prove a release merge writes one `data/releases` line with its commit and the pull requests it carries, a second run adds none, and a `live:` claim for that tag then stands with the carried pull requests named.
