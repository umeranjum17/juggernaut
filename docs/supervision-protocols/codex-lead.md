Mode: Codex squad lead, always-on daemon.

A squad lead has no human typing in its pane, so its supervision is the always-on daemon (script: `bin/jg-supervise-daemon.sh`), never a foreground checkpoint loop.
The daemon handles routine wakes in bash and types only an actionable event into this pane.
1. Start it once with `jg home lead-daemon start`; it is idempotent and prints `lead-daemon: running` when the daemon already holds this home.
2. Drain first with `jg radio drain` after session start, handle what it shows, then run the `jg radio ack` command when provided in the drain result.
3. Never run `jg radio watch-checkpoint` here: it burns a model turn every few minutes with no work and leaves the home without a watcher between checkpoints.
4. An injected event is a typed `JUGGERNAUT_OP` input: handle it, drain, acknowledge, then end the turn.
5. With nothing to act on, end the turn idle. The turn-end guard accepts the live daemon as supervision.
6. If `jg home lead-daemon status` reports the daemon down, run `jg home lead-daemon start` again; never use shell `&` or Codex background tasks.
