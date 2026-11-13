# Gate per-test timeout

A hung landing-gate script is stopped: run `done-done run gate-per-test-timeout` (which runs `tests/jg-test-run.test.sh` and writes its log into the run's folder). It proves that `bin/jg-test-run.sh`, given no bound flag, applies the shipped `script_timeout_seconds` to every script, so a script that sleeps past it is stopped, its children (one in a session of its own) are gone, its temp folder is removed, and the run prints a `JG_TEST_TIMEOUT script=... bound_secs=...` line naming it (screen: none).
