# Fleet flow lane cap

[Fleet flow lane cap](../features/fleet-flow-lane-cap.md): run `bash fleet-flow/tests/jg-flow-check.test.sh`; the real check runs over fixture homes with stub `jg-backlog.sh` and `jg-crew-state.sh` and must free a long wait, a parked lane and a kept copy of a stopped lane (record, worktree and status kept, current-state read no longer working) from the cap while a live working lane and a fresh record still count, with four live lanes plus three kept copies accepting a start and six live lanes refusing one.
