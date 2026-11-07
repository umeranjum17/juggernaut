---
name: watchover-supervision
description: Load whenever /watchover or /radio-silence is invoked, an away or quiet record exists, or a marked away-supervisor message arrives.
user-invocable: false
metadata:
  internal: true
---

# Away and quiet supervision safety

The `/watchover` and `/radio-silence` skills own their respective entry procedures and share the daemon machinery; [architecture](../../../docs/architecture.md) owns the captain-held recheck difference between their postures.
These safety facts apply to both:

- Every current daemon injection uses the `away-supervisor` kind from `bin/jg-operational-input.sh` after `JG_OPERATIONAL_PREFIX` (U+2063 INVISIBLE SEPARATOR followed by `JUGGERNAUT_OP: `), except that a Claude Code primary, which strips U+2063, receives that owner's record-backed doorbell and it counts as marked only when `bin/jg-operational-input.sh open <path>` verifies its record; the `/watchover` skill owns legacy bare-marker compatibility.
- `state/.afk-contract` is the away posture, written in the same turn as `/watchover` before any other work, because `/watchover` is itself the go: no read-back gates entry or waits for a go; entry announces hold-for-return only, and the away session acts on those words by its own judgment through the guarded scripts under standing authority, holding for the return on doubt.
  A record carrying quiet mode (`bin/jg-afk-contract.sh mode`) is quiet mode's instead: the captain is present, it holds nothing for a return, and requested actions proceed under ordinary attended authority.
- While `state/.afk` exists, the daemon owns supervision; do not arm a separate watcher.
  The daemon is never launched on Pi, where the ordinary supervision session continues under the record with main parked: the branch takes every safe actionable wake it can, and only a declined wake (including a broken branch or unsafe scan) or a watcher failure wakes main.
  Away mode on a non-Pi home that runs the supervision host (by default on Claude; `docs/configuration.md` "Supervision host") works the same way with the supervision host as the branch; a wake it hands back arrives through that harness's own wake path and is never the captain's return.
- A marked message while away or quiet mode is active is internal escalation and does not exit that mode.
- A message beginning `/watchover` refreshes away mode; a message beginning `/radio-silence` refreshes quiet mode.
- A Telegram note never means the captain returned, in either mode: only a message typed in the terminal does. In away mode run `bin/jg-afk-return.sh begin --message "<text>"`; it prints `stay` for a note the Telegram gateway filed and changes nothing.
- Any other unmarked message means the captain returned in away mode (load `/watchover`, run the return owner, and do not process that message as ordinary work until its durable catch-up gate clears), or, in quiet mode, is simply answered as ordinary work with the flag and daemon left untouched until an explicit `/radio-silence off`.
- Away and quiet mode never expand approval authority for merges, ask-user findings, destructive actions, irreversible actions, or security-sensitive choices.
- Bias ambiguous input toward exit because a present captain takes precedence.
