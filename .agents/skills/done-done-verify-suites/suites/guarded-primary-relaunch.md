# Guarded primary relaunch

Guarded primary relaunch: run `done-done run -- bash tests/jg-control-primary-relaunch.test.sh`.
The test starts a named Herdr lab session through `bin/jg-herdr-lab.sh` and a stand-in primary in it, then drives the real `bin/jg-control.sh primary relaunch --clear-composer`; inspect the run-owned output for the refused cases (not the locked primary, a person's draft, `--force`), the one relaunch of a primary whose box holds our own stuck doorbell line, the new session taking the lock and the waiting wake, and the refused second call with its row in `data/primary-relaunches.tsv` (screen: none).
