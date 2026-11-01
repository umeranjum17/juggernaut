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

## How a home starts it

A home runs the bus as a **systemd user service**, so the server is up after a
reboot and comes back if it dies. `bin/jg-bus.sh install-service` is the one
command that makes that true, and it is what a release runs:

```sh
export PATH=$HOME/.local/bin:$PATH           # where the install put both tools
JG_HOME=<home> bin/jg-bus.sh install-service  # write the unit if missing, reload, enable --now
JG_HOME=<home> bin/jg-bus.sh status          # nats: up (systemd user service jg-bus.service)
```

- with a systemd user session it writes `jg-bus.service` when the unit is missing
  or names another home, reloads systemd, enables it now, and checks it is active;
- without one (CI, a container, a stripped session) it falls back to
  `bin/jg-bus.sh ensure`, which starts the same server detached from the home's
  `state/bus` directory;
- either way it prints exactly one line - `bus: up ...`, `bus: installed and
  started ...`, or a `bus: cannot start ...` line naming what to fix - and it never
  fails its caller, because a home whose bus cannot start still has to come up.

`bin/jg-bootstrap.sh` runs it at every session start, so a home whose code just
arrived with the bus in it, or a machine that rebooted, has its server up without
anyone starting it by hand. `bin/jg-update.sh` runs it right after the primary
home's fast-forward, so a release can never go live with no message server. `bin/jg-bus.sh
unit` still prints the unit alone, for a hand install.

One config file, sized for the machine. `bin/jg-bus.sh unit` writes
`state/bus/bus.conf` as ONE file: the server config in force plus this machine's
per-home accounts, with no `include` lines. nats-server resolves an include path
against the config's own directory, so an absolute one lands at
`state/bus/home/...` and the server refuses to start. The JetStream budget in that
file is the per-account reservation times the number of accounts, because a global
cap below the sum of the reservations makes the server refuse JetStream with
`insufficient storage resources available (10047)`.

Clients authenticate as their own home. The machine carries one account per home,
so every client call - `bin/jg-kv-lib.sh`'s, and the wake and reply paths that share
it - authenticates as the home that owns the state directory, with the name and the
password in `state/bus/<account>.pass`. A client that connects as the empty user is
refused, and that is what a release without this shipped.

The unit runs the server itself, not `serve`: `serve` starts services and exits,
which a unit would restart forever. `ExecStartPost` runs
`bin/jg-bus.sh bootstrap`, which creates the JetStream stream from
`core/bus/stream.json` (name, subjects, retention) when it is not there, so a
fresh home has its stream before anything publishes.

A home may override any file the services read under `config/bus/`, and the
client address lives in `defaults/captain-channel` (`nats-url`) or the home's
`config/captain-channel`, so a test, or a second home on one machine, runs its
own server on its own port and its own store.

## What CI proves

`.github/workflows/ci.yml`'s `Bus service` lane installs both tools through the
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
parity replay and its own deletion of the code it replaces. `docs/bus-shadow.md`
holds the wake queue and inbox parity work, `docs/captain-channel.md` the captain
channel.
