# Port: Pi engine kit

What Juggernaut needs from the Pi engine kit (`@earendil-works/pi-coding-agent`, `pi-tui`, `pi-ai`): register an extension, subscribe to session events, send a user message, render a widget.

- Adapter: `core/ports/pi-engine/adapter.ts`. Only this file imports the kit's client.
- New Pi code imports from the adapter, never from the kit. If the kit is replaced, only the adapter changes.
- Old importers are listed in `defaults/ports-adapters-legacy`; that list only shrinks.
- Rule and check: `docs/ports-and-adapters.md`, `bin/jg-ports-check.sh`.
