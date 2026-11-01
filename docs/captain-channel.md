# The captain channel

The captain reaches the fleet through one channel: events on a bus, delivered to his iPad, with his replies coming back as events routed to the lead that owns them.
Migration step 5a built that channel in shadow, and this path is now **live**: a captain-facing change of state is recorded, published and delivered to him by this path.

`bin/jg-bus.sh`'s header is the owner of the shape.
This page owns how to run it, how to reverse it, and what its replay proves.

## What is running

`bin/jg-bus.sh serve` starts three services from their files, from the home's `state/bus/` directory so no runtime file lands in the repository.

| Service | File | Role |
| --- | --- | --- |
| `nats-server` with JetStream | [`core/bus/nats.conf`](../core/bus/nats.conf) | messages, history, a week of them |
| `daprd` (slim, no Docker) | [`core/bus/dapr/components/pubsub.yaml`](../core/bus/dapr/components/pubsub.yaml) | the transport binding over NATS |
| `ntfy` | [`core/bus/ntfy.yml`](../core/bus/ntfy.yml) | the captain's iPad surface, on the local server |

The server itself is not started by hand on a real home: a home installs it once
as a systemd user service and `bin/jg-bootstrap.sh` keeps it up. [The message bus](bus-service.md)
owns that install, the unit, and the CI lane that proves a home comes up with
JetStream running.

Every one of them is configured by file and none by code.
The Dapr component decides what the bus really is, so swapping NATS for another broker is a component swap.
A home overrides any of them under `config/bus/`.

`bin/jg-bus.sh status` reports the mode, the delivery target, how many events the record holds, how many did not arrive, and which services are up.
`bin/jg-bus.sh stop` stops the three.
The metric server stays off: a metrics port is shared machine surface and nothing scrapes it yet.
Delivery needs `ntfy` running; the record and the bus need their own services only.

## The path

The three paths that reach the captain's record today are the board (`bin/jg-question-card.sh post`), the supervision branch's captain outcome (`bin/jg-branch-outcome.sh append`), and the away-mode wedge alert (`bin/jg-supervise-daemon.sh`, kind `alert`).
All three send their event through `bin/jg-bus.sh publish`.
A routine or silent outcome is not captain-facing, so it is not sent.

Every event is written to `state/captain-channel.jsonl` **before** anything is published, so an unreachable bus or a stopped service loses nothing.
A transport failure is logged once to `state/captain-channel.log` and the emitter still exits 0: this path runs inside today's own delivery paths and must never break them.

A live delivery that does not arrive is appended to `state/captain-channel-undelivered.jsonl` with its error, and `status` counts them, so a missing notification is named instead of lost.
Nothing retries on its own: the record holds the event and that file names the one that did not arrive.

## The mode switch and its one-step reversal

`defaults/captain-channel` carries the routing and the mode: addresses, subject prefix, stream name, the mode, and the relay switch.
A home overrides any single key at `config/captain-channel`, and `bin/jg-bus.sh config` prints what is in force.

`set mode live` is the shipped value:

- `live` records, publishes and delivers to his iPad.
- `shadow` records and publishes only, so the path observes and nothing he sees changes.
- `off` does nothing at all.

To reverse the switch in one step, put this line in `config/captain-channel`:

```sh
set mode shadow
```

That is the whole reversal: the path goes back to recording and publishing with no delivery, and the record keeps every event that arrives while it is shadow.
Deleting the line, or setting `set mode live`, restores it.
`mode` is the only switch: the shadow tee's own `shadow` and `ntfy-deliver` keys are gone, so no home can turn delivery on without also turning the path live.

## The replay

`bin/jg-bus.sh parity` replays every event in the record through the builder the live path sends with, and compares it with the event the record holds: kind, key, subject, text and link must be identical, so "what he would have seen" and "what he will get" are one diff.
Where an event goes is the one decision the switch flips, so parity reports the delivery target and the delivery count instead of diffing them.

```
captain channel parity: record=<path> events=2 instants=1 decisions=4 deliveries=2 differences=0
captain channel parity: mode live, so each event goes to <url>
```

One row per event per side, and each event makes two decisions the replay compares: what is sent, and where it goes.
`instants` is how many distinct recorded instants the replay covers.
`--record <file>` replays a record copied out of a home instead of this home's own.

`--corrupt` tampers with one replayed event's text on the new path only, and the same diff must then report a difference: a run that stayed green after that would mean the check is vacuous.

What it does not prove: that the emitters still call this path, because their own tests own that.
The replay covers the record this path wrote, which is what a switch can change.

## The relay switch

`set ntfy-relay off` is the shipped value, and it is the only thing that decides where a delivery goes.
Off delivers to `ntfy-server`, the local server this home runs; on would send the same event through `ntfy-relay-server`.
The captain has not answered the relay question, so the local path is the only path built, and turning the relay on is a one-line config change made when he does answer.

## Replies

A reply event is one JSON object, `{"key","at","answer"[,"label"]}`, arriving from his iPad:

```sh
bin/jg-bus.sh reply reply-event.json
```

Routing is not re-decided here.
`bin/jg-board-answers.sh route-answer` sends the reply by the route that command already keeps (`state/board-routes/<card-key>`), with the same marked answer line and the same decision close a board answer uses, so a reply routes to exactly the lead a board answer routes to.
A card with no route is refused, and that answer stays with Main as it does today.

## What this proves, and what is still on the old path

`tests/jg-bus.test.sh` proves the claims.
An event the fleet emits is recorded, published and delivered while the emitting path does what it always did.
The shipped mode is live, and `mode shadow` is the one line that reverses it.
ntfy delivery targets the local server while the relay switch is off, and only the relay when it is on.
A live delivery that fails is named in the undelivered record.
The replay reports what is sent against every recorded event with zero differences, and its tampered run reports one, so a green run is never vacuous.
A reply event routes to the correct lead.
No failure of this path fails its emitter.

[`docs/verification/captain-channel.md`](verification/captain-channel.md) records the dated run of the real services.

Still on the old path, deliberately:

- Every existing delivery route.
  The board, the chat outcome, the status wake, the inbox and the parent channels stay as they are; this path delivers his notification, and those surfaces still hold the record and the decision.
- The live reply loop.
  The router is proven with a reply event handed to it; consuming replies from the bus and arming that loop is a later step.
- Workflows, timers and escalation through Dapr.
  The runtime runs and carries events, and its workflow surface is unused until a step needs it.
- Every event source that has no single emission command yet, such as a worker status line that becomes a wake.
  They reach the channel when their own path gains its emission.
- The other shadow paths of the migration: the wake queue and inboxes, pending replies, leases, and the escalation timers stay in shadow, each with its own parity, until its own switch.
