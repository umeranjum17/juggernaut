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
command, installs the pinned tools, and installs, enables and starts the
NATS unit, the wake engine, the reply router, the Dapr sidecar, then checks the stream. It prints one line
per part, for example `nats  installed 2.10.22, enabled enabled (jg-bus.service),
running pid 123, listening 127.0.0.1:4222` and `wake-engine installed jg-bus, enabled enabled
(jg-wake-engine.service), running pid 456, consuming JG_WAKE/wake-engine`, and a second run prints the same lines.
The first part that cannot be made whole stops the run with one line,
`STACK_FAILED: <part>: <what is missing>; blocks <what depends on it>`.

The Dapr sidecar is one per machine, like the bus unit, so the same owner rule governs them.
Only the home that owns the bus unit (`bin/jg-bus.sh owner` prints `self` there) installs the pinned `daprd`, and writes, enables and starts its unit.
Any other home prints `<part>: owned by <home>, which installs and runs it; this home changes nothing` and reports the part as it finds it, so a second home's session start can no longer rewrite the owner's units or ports.
`tests/jg-stack-owner.test.sh` proves it.

`bin/jg-bootstrap.sh` (every session start), `bin/jg-update.sh` (after the
fast-forward) and `install.sh` all run it, so a release never lands without its
services. Each service is a **systemd user service** (`jg-bus`, `jg-wake-engine`,
`jg-router`, `jg-dapr`) when this account has a user session whose unit directory is this
HOME's; otherwise (CI, a container, a throwaway HOME) the same commands start
detached from the home's `state/bus` through `bin/jg-bus.sh serve`. The units
come from `bin/jg-bus.sh unit [nats|dapr]`. The NATS unit runs the server
itself, not `serve`, which starts services and exits; `ExecStartPost` runs
`bin/jg-bus.sh bootstrap`, which waits for the port and creates the stream from
`core/bus/stream.json`.

`bin/jg-bus.sh install-service` is the bus alone: it writes `jg-bus.service` when missing
(from the home that owns it; any other home only adds its account), reloads systemd, enables it now, and falls back to `ensure` without a
user session. It prints one line, `bus: up ...`, `bus: installed and started ...` or a
`bus: cannot start ...` line, and never fails its caller. `bin/jg-update.sh` runs it when the
stack run is skipped, so a release never goes live with no message server.

One owner, one config. The machine runs one bus unit and one server config, and exactly one
home owns them: the home the installed unit names in its `JG_HOME` (the first home to run
`install-service` when none is installed; `JG_BUS_TAKE_OWNERSHIP=1` moves it here on purpose).
`bin/jg-bus.sh unit` writes the owner's `state/bus/bus.conf` and `state/bus/accounts.conf`.
`bus.conf` is the server config in force plus the JetStream caps, and includes
`accounts.conf` beside it (nats-server resolves an include against the including file's
directory, so the name is relative; an absolute one lands at `state/bus/home/...` and the
server refuses to start). Every other home's bootstrap (`jg-stack.sh up`, which writes the
unit from `jg-bus.sh unit nats`) and update (`install-service`) only registers its account
in the owner's `accounts.conf` and has the running server load it. It never installs or
rewrites the unit and never touches `bus.conf`, and it says who the owner is.
Before this rule every home's session start
pointed the machine's unit at its own config and locked every other home out.

The owner keeps the machine's member list in `state/bus/homes`, one line per home that
joined, and the accounts are written from it. A home under a temp root, or inside the
checkout running the command, is a test fixture and is refused instead of added, naming
the way out: a test or a lab runs a bus of its own and names its own list with
`JG_BUS_HOMES`, so fixture homes are recorded there and a real machine's list stays byte for
byte as it is. That list stands in only for an owner under a temp root. A real owner always
reads its own `homes`, so a fixture that reaches the real unit is refused and never rewrites
the real `accounts.conf` or signals the real server.

A rewritten `accounts.conf` reaches the running server in one of two ways. Accounts only
added load by a reload (SIGHUP, through `systemctl --user kill`). An account taken away
restarts the server, because nats-server keeps a removed account's JetStream reservation until
it restarts. Those kept reservations outgrow the caps, the next new account is refused with
`insufficient memory resources (10028)`, and that refusal ends the reload before JetStream is
back on the accounts it has not reached, so accounts that never left lose it at random.

The JetStream caps in `bus.conf` are the per-account reservation times the accounts in
`accounts.conf` plus one account of headroom, rounded up to a step of eight reservations.
The rounding is what lets a reload add accounts, because a reload cannot change the caps.
A global cap below the sum of the reservations makes the server refuse JetStream with
`insufficient memory resources (10028)` or `insufficient storage resources available (10047)`.
The generator checks the finished config (accounts included) and refuses, naming the
shortfall, to write one whose caps sit below the reservations. A home whose account would
push the machine past the caps is refused the same way, naming the owner, with the accounts
left as they were; run `install-service` on the owner to raise them. `bin/jg-bus.sh
check-limits <config>` runs the same check on any file.

Clients authenticate as their own home. The machine carries one account per home,
so every client call - `bin/jg-kv-lib.sh`'s, and the wake and reply paths that share
it - authenticates as the home that owns the state directory, with the name and the
password in `state/bus/<account>.pass`. `bin/jg-bus.sh login` is the one answer they ask
for, and it answers only when the machine's accounts file really holds that home's
account, so a client connects as nobody on a server that runs no accounts and is never
refused as a user the server does not know. The name itself comes from ONE registry: the
bus owner's `data/squad_leads.md`, the registry its accounts file is generated from, read
by the server block and by every client alike. A home that keeps no registry of its own
therefore names itself exactly as the server recorded it; read from its own empty one it
named itself `home-<hash of its path>`, which the server refused on every call
(Authorization Violation), and that is how a registered home was locked out of the
machine's own bus. Each home keeps its password in its own `state/bus`, and the generator
writes a sibling home's account from that home's file. A client that connects as the
empty user is refused.
No client puts the login on the nats argument list, where `ps` shows it to every user on the machine.
Every other client passes it in `NATS_USER` and `NATS_PASSWORD`; the stream checks write it from the password file to `state/bus/nats-context.json` (mode 0600) and name that file with `--context`.

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

Both log in as the home's own account (`bin/jg-bus.sh login`) when the machine's accounts file
holds it, and `bin/jg-wake-bus.sh` does the same, publishing on `jg.<account>.wake.raise`; a bare
server (a test, a detached stack) takes no login. Before this, the wake client decided from its
own leftover `state/bus/accounts.conf` and the other consumers named the home from a registry of
their own, so on the unit's server the name presented and the name recorded could differ and the
bus could not publish.

An event counts as handled only after its handler returned. The consumer fetches it without
acknowledging it (`jsclient.go`, a small pull client on the standard library, because the Go module
carries no NATS library), runs the handler, and then acknowledges it. While a slow handler runs it
tells the server the event is in progress, so the event is not delivered again under it. A handler that
fails asks the server to deliver the event again after a delay (5 s, then 10 s; `JG_BUS_RETRY_DELAY`
sets the base). After the last try (3; `JG_BUS_MAX_TRIES`) the event is appended with its cause to
`state/bus/<part>.dead.jsonl` and closed, so a failure is kept where it can be read and not dropped.
A crash between the fetch and the acknowledgement leaves the event for the server to deliver again,
which both handlers allow because they are idempotent. The wake watcher follows the same rule for
its fold (`core/bus/cmd/jg-bus/watcher.go`).

A failure other than "nothing arrived" ends the process with its reason, and the unit's
`Restart=always` brings it back; both units require the NATS unit. The stack restarts a
consumer whose binary was rebuilt after it started, so a release never leaves the old
command running.

`bin/jg-bus.sh probe [wake-engine|router]` prints one line per part and exits 1 when the
part has no consumer: the process id, the stream's message count and last sequence, the
consumer's delivered, acknowledged and pending counts, and the engine's own `handled`, `retried` and
`failed` counters (kept in `state/bus/<part>.counts.json`; `failed` counts events on the dead list). Run it before and after a real
wake to see the counters move; a reply the board has no route for stays with Main and is
counted as `retried` for each early try and as `failed` after the last, as `jg-bus reply` refuses it.

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
real wake. `tests/jg-wake-watcher.test.sh` replays recorded `JG_WAKE` events
(`tests/fixtures/wake-recorded/events.jsonl`, 123 events of 52 homes; the full 241-event export replays clean) through the Go fold and the shell reader it replaced and
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

## Health run and outage messages

`jg-bus health run` logs in as every JetStream account in the machine's accounts file and runs `nats stream ls -n` as that account. This is the test that catches error 10028: after a failed reload the server stays up and `nats account info` still exits 0, but the account has no JetStream.

Two failed runs open one outage per service and send one message to the owner. Two passing runs close it and send one more. Each closed outage adds a row to `state/outage-history.jsonl`. A message the chat refused stays queued, the failure goes to the channel log, and the run exits 1. A home with no chat only keeps the history. The run uses no model, no wake path and no herdr.

The run also tests the memory budget (a warning past 80% of the JetStream caps), the reader of the notification engine and of the monitoring loop, and the temporary disk (past 85%). `jg-bus health unit` and `jg-bus health unit timer` print the systemd user service and its 60 second timer. `jg-bus health install` writes both and starts the timer. Only the machine's bus owner runs it. A lab leaves tests out with `JG_HEALTH_SKIP=wake,disk`.
