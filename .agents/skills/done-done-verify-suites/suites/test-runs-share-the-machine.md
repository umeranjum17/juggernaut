# Test runs share the machine

Test runs share the machine: run `done-done run -- bash tests/jg-test-run.test.sh` with the log written into `$DONE_DONE_EVIDENCE_ROOT`; the real `bin/jg-test-run.sh` with `machine_runs_max=1` makes a second run print that it waits for a test-run slot, naming the runner that holds it, and start its script only after that run ends, while a run started inside the admitted run, even one with a cleared environment, never waits; a test script that moves HOME still reports the caller's own Go build cache from `go env GOCACHE`.
The two cases fail on a runner without the slots or the shared cache (screen: none).
