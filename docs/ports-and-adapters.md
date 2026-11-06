# Ports and adapters

Every outside dependency sits behind one port and one adapter, so it can be ripped out without a hunt (owner rule 2026-11-04).

- **Port**: the module or contract that says what Juggernaut needs from the dependency.
- **Adapter**: the one file (or directory) that imports or runs the dependency's client. All other code calls the port.
- **Manifest**: `defaults/ports-adapters` lists each dependency with its port and adapter. Today: the Pi engine kit (`core/ports/pi-engine/`) and the message bus (`core/ports/message-bus/`).

## Checks

`bin/jg-ports-check.sh` runs two checks:

- **Code**: a changed source file that imports or runs a listed client is refused unless it is the adapter or is in `defaults/ports-adapters-legacy`. `bin/jg-lint.sh` runs it on every changed-file run. The legacy list is read at the base ref, so a change cannot add itself. Remove a row when the file moves behind its adapter; never add one.
- **Plan**: `bin/jg-ports-check.sh --plan <file>` refuses a plan or PR text that mentions a listed dependency without naming its port module and an adapter.

## Adding a dependency

In the same change that first uses it: add a row to `defaults/ports-adapters`, write the port module, and write the adapter. `tests/jg-ports-check.test.sh` proves the refusal and the pass.
