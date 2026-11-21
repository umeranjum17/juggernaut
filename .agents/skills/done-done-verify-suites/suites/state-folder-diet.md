# State folder diet

Run `done-done run state-folder-diet` (`bash journeys/state-folder-diet.sh`).
The fixture creates each per-task file and directory listed in `bin/jg-task-files-lib.sh`, runs the real `bin/jg-teardown.sh`, and counts the records before and after cleanup.
`bash tests/jg-teardown.test.sh` also checks the already-cleaned and landed paths.
