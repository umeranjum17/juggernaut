# Release proof

Run `done-done run -- bash tests/jg-trunk-release-open-pr.test.sh` with the test output captured in the run evidence folder.
The isolated trunk release accepts a pre-proof trunk landing, a commit carried by a trunk-home-converge merge and a Revert commit whose revert row names a proven commit, and refuses a commit carried by any other merge, a later missing landing proof and an uncarried hotfix, then retries without another push or release word, tries a failed first read of the published Checks block again, and creates a receipt and evidence card at the release head.
The forge, done-done and sign-off-axi are fixture boundaries; the release capture, caller, merge proof gate and receipt publisher are real.
