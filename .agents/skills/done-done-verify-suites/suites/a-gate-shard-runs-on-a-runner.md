# A gate shard runs on a runner

A gate shard runs on a runner: run `done-done run -- bash tests/jg-runner-shard.test.sh` with the log written into `$DONE_DONE_EVIDENCE_ROOT`; the real `jg_test_host_run_shard` in `bin/jg-test-host-lib.sh` sends the commit as a git bundle through the real `core/runners/run-shard.sh`, `bin/jg-on.sh --stdin` and `bin/jg-runner-shard.sh`, and the shard's JSON comes back from the runner, which ran it at that commit; a red on the runner stays a red, a full runner is skipped and a dead owner's slot is taken over, and a lost runner or a bundle the runner cannot apply reruns the shard here and is never a red; the shard job's own timeout is 1200 s.
Only the SSH process boundary is a stand-in (screen: none).
