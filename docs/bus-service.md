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
NATS unit, the Dapr sidecar, ntfy and the `deliver` consumer that carries the `CAPTAIN` stream to ntfy, then checks the stream. It prints one line
per part, for example `nats  installed 2.10.22, enabled enabled (jg-bus.service),
running pid 123, listening 127.0.0.1:4222`, and a second run prints the same lines.
The first part that cannot be made whole stops the run with one line,
`STACK_FAILED: <part>: <what is missing>; blocks <what depends on it>`.

`bin/jg-bootstrap.sh` (every session start), `bin/jg-update.sh` (after the
fast-forward) and `install.sh` all run it, so a release never lands without its
services. Each service is a **systemd user service** (`jg-bus`, `jg-dapr`,
`jg-ntfy`, `jg-deliver`) when this account has a user session whose unit directory is this
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

Both tools are in the lane, so the test runs for real there instead of
gate-skipping; on a machine without them it skips and says so. The lane is one of
the checks `CI required` gates on, so a change that breaks the install, the unit
or the stream cannot merge green.

## Not in this step

No path switches. The bus exists, is installed, is started and is proven; the
paths that will run their events on it switch one at a time, each with its own
parity replay and its own deletion of the code it replaces. `docs/bus-live.md`
holds the wake queue and inbox switch, `docs/captain-channel.md` the captain
channel.
