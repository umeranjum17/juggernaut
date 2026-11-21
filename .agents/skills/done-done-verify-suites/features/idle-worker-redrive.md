# Idle worker re-drive

`bin/jg-delivery-tick.sh` drives `core/lane-end/idle-redrive.sh`, which sends a durable steer or uses `bin/jg-control.sh` to relaunch an exited worker.
`bin/jg-task-files-lib.sh` retires the lane's retry records during ordinary cleanup.
Run `done-done run idle-worker-redrive` ([suite](../suites/idle-worker-redrive.md)).
