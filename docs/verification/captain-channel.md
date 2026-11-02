# Captain channel: the runtime stack, verified

Date: 2026-11-01.
Host: Linux (Omarchy), amd64.
This record covers the mechanism in [`docs/captain-channel.md`](../captain-channel.md): the three local services started from the shipped files, one event recorded, published and delivered to the captain, the switch between live and shadow, the replay over the record, the reply routing, and a live delivery that does not arrive.
The commands below are the exact ones run, and the output lines are exact excerpts.

## Versions

| Tool | Version | Where it came from |
| --- | --- | --- |
| `nats-server` | v2.10.22 | the project's own release build, on `PATH` for the proof |
| `nats` (client, stream bootstrap only) | 0.5.1 | the project's own release build, on `PATH` for the proof |
| `daprd` | 1.15.5 | `dapr init --slim --runtime-version 1.15.5` |
| `ntfy` | 2.11.0 | the project's own release build, on `PATH` for the proof |

## The services start from the shipped files

```sh
JG_HOME=<home> JG_STATE_OVERRIDE=<home>/state bin/jg-bus.sh serve
```

```text
nats: started (4090021), log <home>/state/bus/nats.log
stream: CAPTAIN ready
dapr: started (4090688), log <home>/state/bus/dapr.log
ntfy: started (4090693), log <home>/state/bus/ntfy.log
```

The only home override in the proof was `set mode live`, which was then the switch a home had to set; `mode live` is the shipped value now, so the same run needs no mode override at all.
The runtime files are `core/bus/nats.conf`, `core/bus/stream.json`, `core/bus/dapr/components/pubsub.yaml` and `core/bus/ntfy.yml`; the Dapr runtime starts with `--enable-metrics=false`, so it binds no shared metrics port.

## One event is recorded, published and delivered

```sh
bin/jg-bus.sh publish card put-the-key-into-muxr "The key choice is waiting on the board." --link https://board.example/cards/put-the-key-into-muxr
nats -s nats://127.0.0.1:4222 stream info CAPTAIN
curl -sS 'http://127.0.0.1:2586/juggernaut-captain/json?poll=1&since=1h'
```

```text
{"at":1793479829,"kind":"card","key":"put-the-key-into-muxr","subject":"jg.captain.card","text":"The key choice is waiting on the board.","link":"https://board.example/cards/put-the-key-into-muxr"}
                     Messages: 1
{"id":"uYEAAEdYeeGw","time":1793479829,"expires":1793566229,"event":"message","topic":"juggernaut-captain","title":"The key choice is waiting on the board.","message":"The key choice is waiting on the board.","tags":["juggernaut"]}
```

`bin/jg-bus.sh config ntfy-relay` printed `off`, and the delivery went to the local server named by `ntfy-server`.
No relay host appears in any request.

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

A card posted through `bin/jg-question-card.sh post` and a captain outcome appended through `bin/jg-branch-outcome.sh append` both arrived on the ntfy topic, with no mode key and no delivery key in the fixture home:

```text
{"path":"/juggernaut-captain","title":"Which key should the muxr use?"}
{"path":"/juggernaut-captain","title":"The key is fixed and released in 0.4.1"}
```

With `set mode shadow` appended to `config/captain-channel`, the same publish is recorded and not delivered:

```text
shadow
delivered to the captain's surface after the reversal: 0 request(s)
```

Deleting that one line restores delivery.

## The replay over the record

```sh
bin/jg-bus.sh parity
bin/jg-bus.sh parity --corrupt
```

```text
captain channel parity: record=<home>/state/captain-channel.jsonl events=2 instants=1 decisions=4 deliveries=2 differences=0
captain channel parity: mode live, so each event goes to http://127.0.0.1:36351/juggernaut-captain
captain channel parity --corrupt: tampered with the replayed event at 1793493975 on the new path: events=2 instants=1 decisions=4 deliveries=2 differences=4 (must be non-zero)
```

## A live delivery that does not arrive

With `set ntfy-server http://127.0.0.1:1`, a server that is not there:

```sh
bin/jg-bus.sh publish card k-lost "This one cannot arrive."
bin/jg-bus.sh status
```

```text
mode live, relay off, delivery http://127.0.0.1:1/juggernaut-captain
record <home>/state/captain-channel.jsonl: 5 event(s), 1 undelivered
```

The undelivered record holds the event with its error:

```text
{"at":1793493976,"target":"http://127.0.0.1:1/juggernaut-captain","error":"curl: (7) Failed to connect to 127.0.0.1:1 ...","event":{"at":1793493976,"kind":"card","key":"k-lost",...}}
```

## The portable proof

`tests/jg-bus.test.sh` carries the same claims without any of these binaries: it stands a local HTTP sink in for the Dapr sidecar and for ntfy, and it drives the real `bin/jg-question-card.sh post`, `bin/jg-branch-outcome.sh append` and `bin/jg-bus.sh reply` against a fixture home.
It proves the shipped live mode, the one-line `mode shadow` reversal, a live delivery that is named in the undelivered record, the replay's zero-difference run and its tampered run, and the reply routing.

## The stack with ntfy logins, over the tailnet address

Date: 2026-11-02.
Host: Linux, amd64, with a tailnet address.
Versions: `nats-server` 2.10.22, `daprd` 1.19.1, `ntfy` 2.36.0.
A throwaway home with free ports ran `bin/jg-stack.sh up` with `config/bus/ntfy.yml` bound to the host's tailnet address, the shipped `deny-all` auth, and no other override.
The machine's own bus unit and state were not touched.

```sh
bin/jg-stack.sh up
bin/jg-captain-probe.sh
bin/jg-stack.sh up
```

```text
ntfy  installed 2.36.0, enabled n/a, detached (no user session for this HOME), running pid <n>, listening <tailnet-ip>:<port>
ntfy: logins ready for topic juggernaut-captain at http://<tailnet-ip>:<port>: publisher juggernaut, captain captain (password in <home>/state/bus/ntfy-captain.pass)
deliver enabled n/a, detached (no user session for this HOME), running pid <n>, consuming CAPTAIN
stream CAPTAIN messages=0; consumer captain-ntfy delivered=0 acked=0 pending=0 ack-pending=0
stream CAPTAIN messages=1; consumer captain-ntfy delivered=1 acked=1 pending=0 ack-pending=0
{"at":1793585870,"subject":"jg.captain.probe","key":"probe-1793585870-3236254","ntfy_id":"eu1puC7vsHBe","target":"http://<tailnet-ip>:<port>/juggernaut-captain"}
captain login read the event: {"id":"eu1puC7vsHBe","time":1793585870,"event":"message","topic":"juggernaut-captain",...}
anonymous publish: HTTP 403; captain (read-only) publish: HTTP 403
probe: PASS bus -> ntfy, stream 0 -> 1, message eu1puC7vsHBe
```

The second `up` printed the same lines and kept both passwords (`-rw-------`).
`tests/jg-stack.test.sh` runs the same journey on a clean home, and `tests/jg-stack-owner.test.sh` proves a home that does not own the bus unit installs, starts and provisions nothing.

Limits of this record: the iPad itself was not subscribed, and the machine's own units were not installed from this branch.
The captain's notification on his iPad needs the owner home to run `bin/jg-stack.sh up` from the merged and released build, plus the two-line tailnet override in [the captain channel](../captain-channel.md#reaching-his-ipad-logins-and-address).
A freshly downloaded `daprd` 1.19.1 release binary segfaulted on `--version` on this host, so `tests/jg-stack.test.sh` could not run from a clean download here; the run above used the already installed `daprd` of the same version.
