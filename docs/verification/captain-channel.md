# Captain channel: the runtime stack, verified

Date: 2026-11-01.
Host: Linux (Omarchy), amd64.
This record covers the mechanism in [`docs/captain-channel.md`](../captain-channel.md): one event recorded and published to the bus, the switch between live and shadow, the replay over the record, and the reply routing.
The commands below are the exact ones run, and the output lines are exact excerpts.
The delivery to a phone surface that the first run also covered was removed from the product, so its steps are gone from this record.

## One event is recorded and published

```sh
bin/jg-bus.sh publish card put-the-key-into-muxr "The key choice is waiting on the board." --link https://board.example/cards/put-the-key-into-muxr
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

`tests/jg-bus.test.sh` carries the same claims without any of these binaries: it drives the real `bin/jg-question-card.sh post`, `bin/jg-branch-outcome.sh append` and `bin/jg-bus.sh reply` against a fixture home.
It proves the shipped live mode, the one-line `mode shadow` reversal, a live event the sidecar refuses that is named in the undelivered record, the replay's zero-difference run and its tampered run, and the reply routing.
