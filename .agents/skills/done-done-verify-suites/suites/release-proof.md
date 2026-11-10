# Release proof

Run `done-done run -- bash tests/jg-trunk-release-open-pr.test.sh` with the test output captured in the run evidence folder.
The isolated trunk release refuses a missing landing proof and an uncarried hotfix, then retries without another push or release word and creates a receipt and evidence card at the release head.
The forge and judge are fixture boundaries; done-done run, the release caller, the merge proof gate and the receipt publisher are real.
