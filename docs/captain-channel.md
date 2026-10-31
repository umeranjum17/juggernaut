# The captain channel

The captain reaches the fleet through one channel: events on a bus, delivered to his iPad, with his replies coming back as events routed to the lead that owns them.
This step (migration step 5a) puts that channel in **shadow**: every captain-facing event is recorded and published, and none of today's delivery paths changes.
Nothing he sees switches until this path's parity is proven.

`bin/jg-bus.sh`'s header is the owner of the shape.
This page owns how to run it.

## What is running

`bin/jg-bus.sh serve` starts three services from their files, from the home's `state/bus/` directory so no runtime file lands in the repository.

| Service | File | Role |
| --- | --- | --- |
| `nats-server` with JetStream | [`core/bus/nats.conf`](../core/bus/nats.conf) | messages, history, a week of them |
| `daprd` (slim, no Docker) | [`core/bus/dapr/components/pubsub.yaml`](../core/bus/dapr/components/pubsub.yaml) | the transport binding over NATS |
| `ntfy` | [`core/bus/ntfy.yml`](../core/bus/ntfy.yml) | the captain's iPad surface, on the local server |

Every one of them is configured by file and none by code.
The Dapr component decides what the bus really is, so swapping NATS for another broker is a component swap.
A home overrides any of them under `config/bus/`.

`bin/jg-bus.sh status` reports what is up and how many events the record holds, and `bin/jg-bus.sh stop` stops the three.
The metric server stays off in this step: a metrics port is shared machine surface and nothing scrapes it yet.

## The shadow tee

The two paths that reach the captain today are the board (`bin/jg-question-card.sh post`) and the supervision branch's captain outcome (`bin/jg-branch-outcome.sh append`).
Both tee their event with `bin/jg-bus.sh publish`, and neither path's own behaviour changes.
A routine or silent outcome is not captain-facing, so it is not teed.

Every event is written to `state/captain-channel.jsonl` **before** anything is published, so an unreachable bus or a stopped service loses nothing.
A transport failure is logged once to `state/captain-channel.log` and the emitter still exits 0: a shadow tee must never break the path it watches.

`defaults/captain-channel` owns the routing: addresses, subject prefix, stream name, whether ntfy delivers, and the relay switch.
A home overrides any single key at `config/captain-channel`, and `bin/jg-bus.sh config` prints what is in force.

## The relay switch

`set ntfy-relay off` is the shipped value, and it is the only thing that decides where a delivery goes.
Off publishes to `ntfy-server`, the local server this home runs; on would send the same event through `ntfy-relay-server`.
The captain has not answered the relay question, so the local path is the only path built, and turning the relay on is a one-line config change made when he does answer.

`set ntfy-deliver off` is separate and also shipped off.
The shadow run records and publishes, and delivers to his iPad only when that is turned on deliberately.

## Replies

A reply event is one JSON object, `{"key","at","answer"[,"label"]}`, arriving from his iPad:

```sh
bin/jg-bus.sh reply reply-event.json
```

Routing is not re-decided here.
`bin/jg-board-answers.sh route-answer` sends the reply by the route that command already keeps (`state/board-routes/<card-key>`), with the same marked answer line and the same decision close a board answer uses, so a reply routes to exactly the lead a board answer routes to.
A card with no route is refused, and that answer stays with Main as it does today.

## What this proves, and what is still on the old path

`tests/jg-bus.test.sh` proves the four claims.
An event the fleet emits is recorded and published while the emitting path does what it always did.
ntfy delivery targets the local server while the relay switch is off, and only the relay when it is on.
A reply event routes to the correct lead.
With the bus unreachable the record still holds every event and the emitter still exits 0.

[`docs/verification/captain-channel.md`](verification/captain-channel.md) records the dated run of the real services.

Still on the old path, deliberately:

- Every existing delivery route.
  The board, the chat outcome, the status wake, the inbox and the parent channels are untouched; the bus observes them and delivers nothing in their place.
- The live reply loop.
  This step proves the router with a reply event handed to it; consuming replies from the bus and arming that loop is the next step.
- Workflows, timers and escalation through Dapr.
  The runtime runs and carries events, and its workflow surface is unused until a step needs it.
- Every event source that has no single emission command yet, such as a worker status line that becomes a wake.
  They reach the bus when their own path gains its tee.
