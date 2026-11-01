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
reboot and comes back if it dies:

```sh
export PATH=$HOME/.local/bin:$PATH           # where the install put both tools
JG_HOME=<home> bin/jg-bus.sh unit > ~/.config/systemd/user/jg-bus.service
systemctl --user daemon-reload
systemctl --user enable --now jg-bus.service
JG_HOME=<home> bin/jg-bus.sh status          # nats: up (<pid>)
JG_HOME=<home> bin/jg-bus.sh ensure          # bus: up nats://127.0.0.1:4222 stream CAPTAIN
```

`bin/jg-bootstrap.sh` does the first three steps for the home it runs in, once,
and then verifies the result with `ensure`:

- with a systemd user session, it writes `jg-bus.service` for this home when the
  unit is missing or names another home, reloads, and enables it;
- without one (CI, a container, a stripped session) it falls back to
  `bin/jg-bus.sh ensure`, which starts the same server detached from the home's
  `state/bus` directory;
- either way it prints one line: `BOOTSTRAP_INFO: bus: up <url> stream <name>`
  when the bus answers, and a `MISSING:` line with the command to run when it
  does not. A home whose bus is down still boots.

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
