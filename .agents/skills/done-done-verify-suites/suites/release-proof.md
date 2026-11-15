# Release proof

Run `done-done run -- bash tests/jg-trunk-release-open-pr.test.sh` with the test output captured in the run evidence folder.
The isolated trunk release accepts a pre-proof trunk landing, a commit carried by a trunk-home-converge merge and a Revert commit whose revert row names a proven commit, and refuses a commit carried by any other merge, a later missing landing proof, an uncarried hotfix and a replacement candidate that omits a release head already pushed, keeps a proof valid at its own head after the green pin moves, then retries without another push or release word, tries a failed first read of the published Checks block again, and creates a receipt and proof card at the release head with no merge-card model judge.
The forge, done-done and sign-off-axi are fixture boundaries; the release capture, caller, merge proof gate and receipt publisher are real.
The rollover journey `bash tests/jg-trunk-rollover.test.sh` re-cuts a trunk whose lanes landed above a merged release, then runs the real release capture on the new head: the log has the Green pin line and one Landing row per commit naming its lane, with no legacy landing.
