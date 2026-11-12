# Release proof status

Run `done-done run -- bash tests/jg-trunk-release-open-pr.test.sh` and `done-done run -- bash tests/jg-pr-merge.test.sh` with the test output captured in the run evidence folder.
A release whose proof passes publishes the status `juggernaut/release-proof` on the release head and one whose proof fails publishes none; the merge command merges a release pull request whose head carries that status as success and refuses one with no status or a newest status of failure; it passes one worker's pull request whose committed receipt names its head and refuses one whose receipt names another commit.
The forge and the trunk's proof script are fixture boundaries; the release caller, the merge command, the status read and the receipt check (`done-done gate`) are real.
