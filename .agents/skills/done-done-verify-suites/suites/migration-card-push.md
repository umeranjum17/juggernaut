# Migration card, push

Migration card, push: run `done-done run -- bash tests/migration-card-live.test.sh`; with a stub probe and a stub chat it proves a row change sends the live table to the captain chat (critical rows first), a pass an hour later sends nothing, a pass after `push-hours` with no change sends one "No migration row changed since" line, and a chat that refuses never costs the board its card; with the Go toolchain it also runs the real `jg-bus.sh gateway push` against a fake Bot API, silent with no token file.
