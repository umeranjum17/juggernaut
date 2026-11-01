# A remote lead's home on the home bus over a leaf node, in shadow

Migration step 5f.
A remote squad_lead home reaches the main home over SSH today: `bin/jg-on.sh` carries one command at a time, stages it in a remote job worker, and returns ssh's exit status.
The bus is already in place, so the same reach can ride it as a leaf node instead: the remote home runs its own message server, that server holds one leaf connection to the home bus, and interest decides what crosses.
This step puts that leaf in shadow.
Both paths run at once, the SSH path stays authoritative, and nothing switches until the replay below is green.

`bin/jg-bus-leaf.sh` is the one owner of the mechanics: the two server configurations, the canonical event row, the two-sided replay, and the deliberate corruption that keeps that replay from being vacuous.
Nothing here changes the file path's plumbing, and `parity` writes only under its own directory.

## What runs

- Two server configurations, both rendered from one key file
  (`defaults/bus-leaf`, then the home's `config/bus-leaf`, then `JG_BUS_LEAF_<KEY>`):
  the home bus side is the base bus configuration in force plus one `leafnodes`
  block, and the remote side is its own server with one remote dialling that
  block's address as the configured user.
  Nothing is passed on a command line, and no address, subject or credential is
  hard-coded in the script.
- `jg-bus-leaf.sh serve hub|leaf` starts either side and records where it is
  listening, read back from the server's own log, so a listener on any free port
  is usable without guessing.
  `stop` stops what `serve` started.
  In shadow that command starts the bus side for a run; giving a home's
  long-running bus service the same block is part of the switch, and until then the
  listener exists exactly where an operator or a replay starts it.
- The leaf runs when an operator starts it; there is no per-poll switch file,
  because a leaf connection is not a per-poll cost the way the wake and state
  mirrors are.
- `send` publishes one event, or a batch of rows from stdin, on the subject the
  key file names.
  A batch goes out on one connection, in the order it is written, because the order
  the server receives is the order this step has to prove.
- `consume` subscribes on the leaf's own address and applies every event it
  receives to the home it is given.

## The event model

One row is the whole vocabulary, and each kind lands on the surface of the lead's
home that already holds it today:

| kind | what the row becomes | written by |
| --- | --- | --- |
| `task` | a steering-inbox record for that task | `bin/jg-task-inbox-lib.sh` |
| `status` | one appended line in `state/<task>.status` | the same append the brief tells a worker to use |
| `wake` | one durable queue row | `bin/jg-wake-lib.sh` |

The ordered view of what the home received is `bus-leaf-view.tsv`: one row per
applied event, `<index> <tab> <kind> <tab> <key> <tab> <payload>`, appended only
after that event's own record write succeeded.
Its line count is the applied index, so an event applies exactly once and in
order: an index that is not the next one is a repeat or a gap and is ignored, and
the sender resends from the first missing index.

The row is the transport's too: a published body carries the same four fields with
the key and payload base64-encoded, so one event is one line whatever the payload
holds, and a task body with newlines or tabs in it cannot split a row.

## The parity contract

`jg-bus-leaf.sh parity --route <lead> --state <dir>` runs one fixed event set - two
tasks, two wakes and two status lines, ending with a third task - twice, once per
path, and compares the two ordered views row by row.

- The **SSH leg** calls the real transport, `bin/jg-on.sh`, once per event, so the
  order the lead sees is the order the caller sent.
- The **leaf leg** starts a hub and a leaf from the rendered configurations,
  subscribes on the leaf's own client address, and publishes the same set on the
  hub. Interest is what makes it cross the leaf connection.
- Both legs write into their own directory under `--state`, so a run never touches
  a real home's records, and the servers are its own, on free ports.
- Each side must hold the whole set before the comparison, so two empty views can
  never compare equal.
- `--corrupt` tampers with one event on the leaf leg. A run that stayed green
  after that would mean the comparison is vacuous, so it must report the
  difference and exit non-zero.

The output is `rows=<n> differences=<n> route=<id>`, and a difference is the
`diff` of the two views, which names the row and the field that differs.

### What it does not prove

The replay compares consumer results for one fixed set of three event kinds.
It does not prove a live lead's own reads: the switch is what replaces a lead's
file reads and its doorbells with bus subscriptions, and neither side of that
change is modelled here.
It does not prove reconnect or delivery across a dropped leaf connection, because
a batch that fails to apply is resent within one run rather than across a
reconnect.
It does not prove authentication or transport security beyond the one configured
user, and the shipped credential is a local-only placeholder.
It does not prove the home's long-running bus carrying the leaf block either,
because that wiring belongs to the switch.
And it says nothing about the SSH job machinery the SSH leg rides: staging,
cancellation and exit-status preservation are the SSH path's own contract, proven
by `tests/jg-on.test.sh`, and they are neither replaced nor exercised in depth here.

## Measured

Measured on the branch that added this, with `wc -l` and the spans named here;
nothing below is an estimate.

Leaf path, `bin/jg-bus-leaf.sh`: 581 lines.

- 93 header, usage, and the paths one run resolves.
- 48 for the key file, in three functions: the environment file and home override,
  the config-file value, and the field and endpoint validation that refuses a value
  that could break the file it is rendered into, in the caller's own shell so a
  refusal is never lost to a subshell.
- 44 for the two server configurations, one function each.
- 92 for the servers and the live topology: the client and server gates, the log
  reads that discover an address, start and stop, `serve`, and `config`.
- 75 for the canonical row and `apply`: the row, the applied-index read, the
  ordered view, and the three record writes.
- 61 for the transport: the row encoder, `send`, `consume`, `dump`.
- 147 for the replay: the fixed event set, the SSH leg, the leaf leg with its
  ordered batch and bounded retries, the per-leg check, the comparison, and the
  cleanup that stops a run's servers.
- 21 for argument dispatch.

Plus 34 lines of `defaults/bus-leaf`, and the two external binaries
`nats-server` and `nats`.

SSH path, what a remote lead's commands cost today: `bin/jg-on.sh` 147,
`bin/jg-remote-entrypoint.sh` 215, `bin/jg-remote-job-lib.sh` 1499 and
`bin/jg-remote-job-worker.sh` 1361, which is 3,222 lines.
That is the cost of running one command on another host at all: staging, a
supervisor, cancellation, bounded stdin, and an exit status that survives a
dropped connection.

A switch is therefore not "3,222 lines become 615", and this step claims no such
thing:

- those 3,222 lines also carry file transfer, peeks, follow-ups and inherited
  material, so only the part that carries task, status and wake events would go;
- the leaf path adds what SSH does not have here - one connection that stays up,
  history, and a second home reading the same subject - and it adds the two
  external binaries and their configuration;
- the event-shape code the leaf path replaces is the per-kind remote command, not
  the job transport: `bin/jg-remote-delta-read.sh` (253 lines) reads a status delta
  over SSH, file delivery for a task is `bin/jg-remote-file.sh` (256) plus the
  receiver, and a wake for a remote home is raised in that home today rather than
  from the main home.

## Replaying a real lead

```sh
# one registered remote lead, into a scratch directory that is not a live home
bin/jg-bus-leaf.sh parity --route <squad-lead-id> --state /tmp/bus-leaf-parity
bin/jg-bus-leaf.sh parity --route <squad-lead-id> --state /tmp/bus-leaf-parity --corrupt
```

`--state` must be absolute, and both legs write only inside it: `ssh/` and `leaf/`
hold the two views, `servers/` holds the two server logs and the servers
themselves, and `parity.diff` is the comparison.
A run over a real route executes one SSH call per event against the lead's host,
into that scratch directory and not into the lead's state.

## Test

`tests/jg-bus-leaf-parity.test.sh` runs throwaway servers on free ports and proves
four things: one configuration file brings the remote home onto the bus as a leaf
node, the same seven events reach the same home in the same order over both paths,
each leg applies them to the lead's own steering, status and wake records, and one
event deliberately corrupted on the leaf path fails the same comparison.
The ssh process boundary in the test is a local executable that runs the same
argv the transport produces, so no second host is needed and the SSH call is still
the replay's own; it refuses any other host or entrypoint, so a replay that
stopped using `bin/jg-on.sh` fails instead of quietly passing.
The test gate-skips when `nats-server` or the `nats` client is missing; set
`JG_NATS_SERVER` and `JG_NATS_BIN` to pin them.
