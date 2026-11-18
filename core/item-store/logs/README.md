# Log readers for the stamp check

The tick's stamp check compares every move stamped by an `owner:` channel or by a closer adapter with that channel's own log.
A reader is an executable file in this folder named for the stamp, with its first `:` written as `-`: `owner-chat` reads the
log of `owner:chat`, `adapter-trunk` reads the log of `adapter:trunk`.

- It prints one `<source>\t<item key>` line per record, tab separated, and exits 0. `<source>` is exactly the move's
  source, channel prefix included (his chat answer: `chat:<message id>`), because the check looks up the pair (the move's
  source, its item key).
- `jg-item tick` (main home only) and `jg-item stamp-check` run each reader with no arguments and no input. If a reader exits
  non-zero, the stamp check is skipped for that run (a broken reader must not make every move look forged): the tick prints
  one `item-store: stamp check skipped: ...` line, once per distinct cause, and `stamp-check` exits 1.
- Every `owner:` channel and every adapter in the kind view's closer column is always checked. A channel with no reader here
  has an empty log, so every move it stamped is reported, once, as a security item on Main and a line in
  `state/item-store/tick.log`. Each slice that adds a writer stamped by a channel ships that channel's reader with it.
- Slice 1 ships no reader: in slice 1 nothing stamped by an owner channel or a closer adapter is written in live use.
