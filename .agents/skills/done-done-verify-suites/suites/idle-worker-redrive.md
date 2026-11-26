# Idle worker re-drive

Run `done-done run -- bash tests/jg-idle-redrive.test.sh` from the repository root.
The journey writes `idle-worker-redrive.log` into the run's evidence directory.
The real delivery tick and durable send run against a private tmux server with synthetic turn events.
The fixture exercises an unfinished idle worker, a busy turn, an unsent draft, closing statuses, a declared wait, an exhausted steer, and a refused relaunch that preserves the worker's local changes.
The real control command refuses an automatic relaunch while the agent is alive, and a recording replacement captures the request after the agent exits.
