# Live pipeline check

Live pipeline check: run `done-done run -- bash tests/jg-check-live-pipeline.test.sh` with the log written into `$DONE_DONE_EVIDENCE_ROOT`; the real `bin/jg-check-live-pipeline.sh` over fixture homes with a stand-in pipeline CLI exits 1 and names the home, task and status while a ship task's run is in flight, and exits 0 once every run has ended, for a scout, a worktree the pipeline does not know, a gone worktree, and a missing CLI (screen: none).
