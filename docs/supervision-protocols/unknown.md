Mode: Unknown harness fallback.

This primary harness does not have a verified watcher wake adapter.
Follow the generic supervision contract in `AGENTS.md`.
First cycle: drain queued wakes, then choose a supervision wait that the harness can actually wake from.
Ordinary wake: drain, handle all emitted wakes, reconcile open decisions and unread status lines, and run the `jg radio ack` command when provided in the drain result, then repeat that verified wait while supervision is still required.
Before that acknowledgement, interruption leaves the work durable for idempotent re-handling.
Use `jg radio watch-arm` only when the harness has a tracked background mechanism that survives the tool call and notifies the model on process exit.
Use a bounded foreground wait over `bin/jg-watch.sh` when that wake mechanism is not verified.
Never use shell `&` for watcher supervision.
Failure or missing cycle only: inspect the failure and restore the same verified wait shape.

Record new verification evidence before promoting an unknown harness to a named snippet.
