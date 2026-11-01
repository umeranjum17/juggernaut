# The message bus: how a home gets a running JetStream

Every live path in the migration (the captain channel, the wake queue and the
task inboxes, the pending replies, the state mirror) runs on one NATS JetStream
server per home. This page is the one owner of how that server exists: how it is
installed, how a home starts it, and how CI proves a home comes up with it
running. `bin/jg-bus.sh` owns the commands; nothing else restates them.

## The tools, pinned

`toolchain.versions` carries both binaries at their exact versions:

| tool | row | what it is |
| --- | --- | --- |
| `nats-server` | `2.10.22` | the JetStream server |
| `nats` | `0.5.1` | the client the stream commands use |

Both ship as release archives, not npm packages, so the installer reads those
rows and `bin/jg-bootstrap.sh` owns the download: the asset for this platform
(linux or darwin, amd64 or arm64) is fetched from `nats-io/nats-server` or
`nats-io/natscli` at the pinned version, unpacked, and installed into the same
user-local bin directory every other tool lands in (`~/.local/bin` by default).
`bin/jg-bootstrap.sh install nats-server nats` is that step on its own, and
`install.sh` runs it with everything else on a clean machine.

## Accounts: one per home, named by the home's id

Each home has its own account, user and credentials file in `state/bus/<account>.pass`.
The account is the home's unique id, never its folder name, because every Squad Lead
home folder can share one basename: a registered Squad Lead uses its `data/squad_leads.md`
id, and any other home (Main included) uses `home-<12 hex of sha256 of its resolved
absolute path>`. `bin/jg-bus.sh account` prints this home's account and credentials file.
The generated accounts file holds Main plus every `data/squad_leads.md` entry. Two homes
that land on one name are refused with one line naming both, so rename a Squad Lead id.

Upgrading an existing install: a home whose folder name is unique keeps its old
password, moved once from `<folder>.pass` to its new account. A folder name shared by
several homes named no single home, so each of those homes gets a new password and the
old shared file is left unused. Either way, re-run `bin/jg-bus.sh unit` and
`systemctl --user restart jg-bus.service` once so the server reads the new accounts.

## How a home starts it: one command

```sh
bin/jg-stack.sh up          # install what is missing, start what is stopped, report every part
bin/jg-stack.sh status      # the same report, changing nothing
```

On a fresh clone this one command brings the whole stack up: it builds the Go
command, installs the four pinned tools, and installs, enables and starts the
NATS unit, the wake engine, the reply router, the Dapr sidecar, ntfy and the `deliver` consumer that carries the `CAPTAIN` stream to ntfy, then checks the stream. It prints one line
per part, for example `nats  installed 2.10.22, enabled enabled (jg-bus.service),
running pid 123, listening 127.0.0.1:4222` and `wake-engine installed jg-bus, enabled enabled
(jg-wake-engine.service), running pid 456, consuming JG_WAKE/wake-engine`, and a second run prints the same lines.
The first part that cannot be made whole stops the run with one line,
`STACK_FAILED: <part>: <what is missing>; blocks <what depends on it>`.

`bin/jg-bootstrap.sh` (every session start), `bin/jg-update.sh` (after the
fast-forward) and `install.sh` all run it, so a release never lands without its
services. Each service is a **systemd user service** (`jg-bus`, `jg-wake-engine`,
`jg-router`, `jg-dapr`, `jg-ntfy`, `jg-deliver`) when this account has a user session whose unit directory is this
HOME's; otherwise (CI, a container, a throwaway HOME) the same commands start
detached from the home's `state/bus` through `bin/jg-bus.sh serve`. The units
come from `bin/jg-bus.sh unit [nats|dapr|ntfy]`. The NATS unit runs the server
itself, not `serve`, which starts services and exits; `ExecStartPost` runs
`bin/jg-bus.sh bootstrap`, which waits for the port and creates the stream from
`core/bus/stream.json`.

Three config faults made the first unit fail on a real machine and are fixed:
includes were absolute (nats resolves them against the including file), the
server store caps sat below the per-account reservations (so the server refused
its own accounts), and the stream client and the sidecar connected with an empty
user (the accounts file refuses that; both now log in as the home's account).

A home may override any file the services read under `config/bus/`, and the
client address lives in `defaults/captain-channel` (`nats-url`) or the home's
`config/captain-channel`, so a test, or a second home on one machine, runs its
own server on its own port and its own store.

## The wake engine and the reply router

`jg-bus wake-engine` and `jg-bus router` (`core/bus/cmd/jg-bus/engine.go`) are the two
long-running consumers. Each owns one durable pull consumer, so an event raised while the
service was down is delivered when it returns:

| service | reads | does with each event |
| --- | --- | --- |
| `jg-wake-engine` | the wake raises of this home on `JG_WAKE` (the endpoint `bin/jg-wake-bus.sh endpoint` names) | runs the render, so `state/.wake-queue` holds the wake without a caller running a render |
| `jg-router` | `<subject-prefix>.reply` on `CAPTAIN` (`jg.captain.reply`), body `{"key","at","answer"[,"label"]}` | routes the reply by `jg-bus reply`'s rule, the board's own route |

Both log in as the home's own account (`bin/jg-bus.sh account`) when the home has an accounts
server, and `bin/jg-wake-bus.sh` does the same, publishing on `jg.<account>.wake.raise`; a bare
server (a test, a detached stack) takes no login. Before this, the client logged in under the
folder name the account no longer carries, so on the unit's server the stack stopped at the
CAPTAIN stream and the wake bus could not publish.

A failure other than "nothing arrived" ends the process with its reason, and the unit's
`Restart=always` brings it back; both units require the NATS unit. The stack restarts a
consumer whose binary was rebuilt after it started, so a release never leaves the old
command running.

`bin/jg-bus.sh probe [wake-engine|router]` prints one line per part and exits 1 when the
part has no consumer: the process id, the stream's message count and last sequence, the
consumer's delivered, acknowledged and pending counts, and the engine's own `handled` and
`failed` counters (kept in `state/bus/<part>.counts.json`). Run it before and after a real
wake to see the counters move; a reply the board has no route for stays with Main and is
counted as `failed`, as `jg-bus reply` refuses it.

Dapr is installed and started by the stack as before. The engine and the router do not use
it: they read the stream directly, which the existing decision allows because Dapr carries
only the captain channel's publish path.

## The wake watcher

`jg-bus wake-watcher` (`core/bus/cmd/jg-bus/watcher.go`) is a third consumer: a durable pull
consumer named `wake-watcher` on `jg.<account>.wake.>`, so it sees raises and acknowledgements
in order. It folds them into the unsettled queue rows (`state/bus/wake-watcher.fold.json`),
the same fold the render applies, and the watcher (`bin/jg-watch.sh`) asks it, through
`jg-bus watcher oldest|latest|resurfaced`, for two things it used to read out of
`state/.wake-queue` every poll: the oldest wake nobody handled and how long it has been the
oldest (`own_queue_resurface`), and the newest host-memory wake (`host_memory_surface_queued`).
The watcher no longer opens the queue file for either, and `state/.own-wake-progress` is gone.

Two cases keep the answer honest when the fold is not the whole story. The events a home still
owes the bus (`state/.wake-bus.outbox.jsonl`) are applied after the fold, as the render does, so
a home whose bus is off or down keeps resurfacing what it queued. When the service is not
running its fold is not trusted: the view is the render's own inputs (the replica
`state/.wake-bus.events.jsonl`, then the owed events), the command says so on stderr, and the
watcher writes one line to its triage log per change. Run `bin/jg-bus.sh watcher rebuild` and
restart the service to replay the stream from the start.

`bin/jg-bus.sh probe wake-watcher` shows the consumer's acknowledged counter; it rises with each
real wake. `tests/jg-wake-watcher.test.sh` replays every recorded `JG_WAKE` event
(`tests/fixtures/wake-recorded/events.jsonl`) through the Go fold and the shell reader it replaced and
requires identical answers after each event, with a corrupted control that must fail, then proves
the service, the counter and the watcher cycle on a throwaway server.

What stays shell in `bin/jg-watch.sh` for now: everything that produces a wake by polling (status
files, panes, pull requests, checks, steering inboxes, squad lead ticks), the reading of a squad
lead's own queue file, and the print-and-exit wrapper every harness adapter waits on. Each is
its own later slice.

## What CI proves

`.github/workflows/ci.yml`'s `Bus service` lane also runs `tests/jg-stack.test.sh`: one command on a clean HOME brings every part up, a second run changes nothing, and a broken part stops the run with one line. It installs both tools through the
command above - the repository's own install path, not a hand-written download -
and then runs `tests/jg-bus-service.test.sh`. That test starts a throwaway home,
runs `ensure` twice, and asserts:

- the line names the server address and the stream `core/bus/stream.json` names;
- the stream exists with the subjects its file names;
- a second `ensure` changes nothing: no second stream, same creation time;
- a published event is accepted and kept by the stream;
- a stopped server comes back with one `ensure`.

`tests/jg-wake-engine.test.sh` runs both consumers against a throwaway server: a raised
wake is handled and the counter rises, a wake raised while the engine is down is handled
after its restart, and a captain reply reaches the router. Both tools are in the lane, so the test runs for real there instead of
gate-skipping; on a machine without them it skips and says so. The lane is one of
the checks `CI required` gates on, so a change that breaks the install, the unit
or the stream cannot merge green.

## Not in this step

No path switches. The bus exists, is installed, is started and is proven; the
paths that will run their events on it switch one at a time, each with its own
parity replay and its own deletion of the code it replaces. `docs/bus-live.md`
holds the wake queue and inbox switch, `docs/captain-channel.md` the captain
channel.
