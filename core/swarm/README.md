# swarm

A swarm runs a plan's slices across Main and the lead homes. This check keeps Main told and keeps the owner's word rows tended.
One watcher check does both, in every home that has armed a swarm.

`wiring.sh [--dry-run] <jg-home>` installs and registers it. It writes the home's `state/swarm.check.sh`, which runs `bin/jg-swarm-words.sh <home>` and then `bin/jg-swarm-check.sh check <home>`.
Nothing is copied: the home's own scripts run.

## What the check does

In Main, each line once:

- `swarm <plan>: all <n> slices landed in <h>h<mm>m`. The swarm is then `finished`.
- `swarm <plan>: all runnable slices landed; <k> wait for the owner: <rows>`.
- `swarm <plan>: no slice moved for <m> min; open: <row> (<reason>)`. It repeats only when the counts change, and only while a slice is open and none is in flight.

In an armed home, once: `swarm <plan>: <owner> restored its dispatch switch to <value>`. A finished swarm puts back the switch it found.

The check in Main raises a P1 that names the lane and its owner when a worker's open blocker is more than ten minutes old.
It uses the blocker's recorded time when present and starts timing an unstamped blocker on the first observation.
The same lane keeps one alert until its blocker closes or the lane lands.

When a lead claims a handled steer with `bin/jg-delivery.sh`, the command records the action and evidence for each lane named in the message and assigned to that lead's swarms.
The records stay under the lead's `state/swarm-actions/`, even for a steer delivered from Main's inbox.

## What the word-row upkeep does

- A lead takes the owner's pick from Main. When Main's card is answered, the lead runs `design-pick` with his words, and the slice starts with no model turn.
- A word row whose gate is answered is closed with the note `answered on the board`.
- It prints nothing. A home or plan it cannot read goes to stderr, and it goes on.

## Records and setting

- Reads: `data/swarm/<plan>/swarm.json` (Main), `data/swarm/<plan>/arm.json` (each owner home) and the derived `plan.json` they name.
- Writes: `state/swarm.check.sh`, `data/swarm/<plan>/swarm.json` state and the word rows.
- `config/swarm-stall-minutes`: minutes without a landing before the stall line (default 30).

## Wire and retire

- Wire: `core/swarm/wiring.sh <home>` in Main and in each lead home. Use `--dry-run` first.
- Retire: `bin/jg-check-unregister.sh swarm` in each wired home.

Proof: `tests/jg-swarm-wiring.test.sh`.
