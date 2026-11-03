# Captain channel: the runtime stack, verified

Date: 2026-11-01.
Host: Linux (Omarchy), amd64.
This record covers the mechanism in [`docs/captain-channel.md`](../captain-channel.md): the local services started from the shipped files, one event recorded and published to the bus, the switch between live and shadow, the replay over the record, and the reply routing.
The commands below are the exact ones run, and the output lines are exact excerpts.
The delivery to a phone surface that the first run also covered was removed from the product, so its steps are gone from this record.

## Versions

| Tool | Version | Where it came from |
| --- | --- | --- |
| `nats-server` | v2.10.22 | the project's own release build, on `PATH` for the proof |
| `nats` (client, stream bootstrap only) | 0.5.1 | the project's own release build, on `PATH` for the proof |
| `daprd` | 1.15.5 | `dapr init --slim --runtime-version 1.15.5` |

## The services start from the shipped files

```sh
JG_HOME=<home> JG_STATE_OVERRIDE=<home>/state bin/jg-bus.sh serve
```

```text
nats: started (4090021), log <home>/state/bus/nats.log
stream: CAPTAIN ready
dapr: started (4090688), log <home>/state/bus/dapr.log
```

The only home override in the proof was `set mode live`, which was then the switch a home had to set; `mode live` is the shipped value now, so the same run needs no mode override at all.
The runtime files are `core/bus/nats.conf`, `core/bus/stream.json`, and `core/bus/dapr/components/pubsub.yaml`; the Dapr runtime starts with `--enable-metrics=false`, so it binds no shared metrics port.

## One event is recorded and published

```sh
bin/jg-bus.sh publish card put-the-key-into-muxr "The key choice is waiting on the board." --link https://board.example/cards/put-the-key-into-muxr
nats -s nats://127.0.0.1:4222 stream info CAPTAIN
```

```text
{"at":1793479829,"kind":"card","key":"put-the-key-into-muxr","subject":"jg.captain.card","text":"The key choice is waiting on the board.","link":"https://board.example/cards/put-the-key-into-muxr"}
                     Messages: 1
```

The stream holds the one message.

## A reply event routes to the routed lead

```sh
bin/jg-bus.sh reply reply.json
```

```text
routed: put-the-key-into-muxr -> lead1
```

The lead's inbox holds the marked line, and its decision key closed:

```text
board-answer [key=put-the-key-into-muxr at=2026-11-01T00:00:00Z]: the captain answered "yes, key it" (Answered in chat). Move this record to handled/ to acknowledge; no other reply is owed.
resolved [key=put-the-key-into-muxr] [at=1793479829]: answered: board-answer [key=put-the-key-into-muxr at=2026-11-01T00:00:00Z]: ...
```

An unrouted card is refused and reaches no lead:

```text
jg-board-answers: refused: card unrouted-card is not routed to a lead, so its answer stays with Main as it does today
exit: 3
```

## The switch is live, and one line reverses it

The mode is the shipped value, so a home with no mode key of its own is live:

```sh
bin/jg-bus.sh config mode
```

```text
live
```

A card posted through `bin/jg-question-card.sh post` and a captain outcome appended through `bin/jg-branch-outcome.sh append` both reached the bus, with no mode key in the fixture home.
`tests/jg-bus.test.sh` proves it against the real emitters.

With `set mode shadow` appended to `config/captain-channel`, the same publish is still recorded and published, and only the undelivered accounting stops:

```text
shadow
```

Deleting that one line restores live mode.

## The replay over the record

```sh
bin/jg-bus.sh parity
bin/jg-bus.sh parity --corrupt
```

```text
captain channel parity: record=<home>/state/captain-channel.jsonl events=2 instants=1 decisions=4 deliveries=2 differences=0
captain channel parity --corrupt: tampered with the replayed event at 1793493975 on the new path: events=2 instants=1 decisions=4 deliveries=2 differences=4 (must be non-zero)
```

## The portable proof

`tests/jg-bus.test.sh` carries the same claims without any of these binaries: it stands a local HTTP sink in for the Dapr sidecar, and it drives the real `bin/jg-question-card.sh post`, `bin/jg-branch-outcome.sh append` and `bin/jg-bus.sh reply` against a fixture home.
It proves the shipped live mode, the one-line `mode shadow` reversal, a live event the sidecar refuses that is named in the undelivered record, the replay's zero-difference run and its tampered run, and the reply routing.
