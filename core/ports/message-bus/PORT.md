# Port: message bus

What Juggernaut needs from the message bus: publish a captain-channel record and read it back.

- Adapter: `core/bus/cmd/jg-bus/`. The chat sends in-process, the wake queue keeps its local files and the task leases live in `state/kv.db`; no broker runs.
- Everything else calls `bin/jg-bus.sh`.
- Old direct users are listed in `defaults/ports-adapters-legacy`; that list only shrinks.
- Rule and check: `docs/ports-and-adapters.md`, `bin/jg-ports-check.sh`.
