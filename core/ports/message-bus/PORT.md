# Port: message bus

What Juggernaut needs from the message bus (today NATS JetStream): publish a captain-channel record, read it back, run the bus services.

- Adapter: `core/bus/cmd/jg-bus/`. Only this directory imports a bus client library or runs `nats` / `nats-server` itself.
- Everything else calls `bin/jg-bus.sh`. If NATS is replaced, only the adapter changes.
- Old direct users are listed in `defaults/ports-adapters-legacy`; that list only shrinks.
- Rule and check: `docs/ports-and-adapters.md`, `bin/jg-ports-check.sh`.
