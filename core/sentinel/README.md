# sentinel

The restart-recovery feature. The sentinel runs outside the agent runtime, so it
survives a runtime restart that kills every agent and watcher in the runtime
server's process tree. It re-arms supervision: it reconciles the home's direct
reports, relaunches a lane that came back outside its recorded worktree, nudges
a lane whose turn was lost, and wakes the primary session.

The sentinel's own code lives here (`bin/jg-sentinel.sh`), and this is its only
copy: the repository's `bin/jg-sentinel.sh` is a forwarder that execs it with
`JG_BIN` set to that checkout's `bin/`, so the copy the host runs and the copy a
checkout runs are one file. It calls the host tool's scripts and libraries from
`JG_BIN` when set, else from the home's checkout (`$JG_HOME/bin`), and copies
none of them. Each tick also guards `/tmp` use through `bin/jg-tmp-sweep.sh`,
rings the primary at once for a queued captain note when no watcher is live
(`ring`, which `bin/jg-inbox.sh` runs), and sends the captain one alert when a
wake stays deferred. After a Herdr restart it also restores a recorded Claude model when a direct
report resumed without its `--model` argument, then checks each registered,
local, unparked lead home with that home's own sentinel state and relaunch tools.

## Layout

- `bin/jg-sentinel.sh` — the sentinel: `tick`, `loop`, `ring`, `reconcile`,
  `unit`, `model-reconcile` and `lead-model-reconcile`. Its CLI, state files and
  knobs are documented in its header. A sentinel change is made here, never in a
  second copy.
- `wiring.sh` — copies the sentinel to `${XDG_DATA_HOME:-$HOME/.local/share}/jg-sentinel`
  and points the `jg-sentinel` user unit at that copy for one home.
- `unwiring.sh` — restores the unit to its text from before the first install,
  restarts the service on it, and removes the installed copy.
- `tests/` — see Checks.

## Install

    sentinel/wiring.sh [--dry-run] <jg-home>

Install is idempotent. It records the unit as it was before the first install
(`unit.before` in the installed copy's folder), and writes a timestamped
`jg-sentinel.service.bak-sentinel-addon-<epoch>` beside the unit whenever a
later install replaces a unit it did not write. It restarts the service in the
same step it rewrites the unit, so the sentinel never stops without starting
again. A rerun with nothing to change prints `already installed` and restarts
nothing. `--dry-run` prints the unit and copy changes and writes nothing.

## Uninstall

    sentinel/unwiring.sh [--dry-run]

Uninstall writes back the pre-install unit, restarts the service on it, and
removes the installed copy, so after install and uninstall the unit is the one
from before. It refuses when no unit existed before install, because a restart
then would have nothing to restore to; the sentinel keeps running until the
owner stops it by hand. Running it again when nothing is installed prints
`not installed`.

## Checks

- `bash sentinel/tests/jg-sentinel-install.test.sh` — hermetic: a throwaway HOME
  and XDG dirs and a stub `systemctl` on `PATH`. The real user manager is never
  read or changed.
- `bash sentinel/tests/jg-sentinel-model-relaunch.test.sh` — fixture-based check
  that only a Claude pane missing its recorded model is relaunched, once per event.
- `bash sentinel/tests/jg-sentinel-one-copy.test.sh` — hermetic: the repository's
  `bin/jg-sentinel.sh` is a short forwarder, the installed copy is this file byte
  for byte, and one tick through the installed copy and through the forwarder
  warns on `/tmp` use, defers the wake and sends one captain alert; both entries
  refuse `unit` in a Squad Lead home.
- `sentinel/tests/jg-sentinel-dead-relaunch.test.sh`,
  `jg-sentinel-restart-resume.test.sh` and `jg-sentinel-herdr-restart-live-e2e.test.sh`
  run this copy against a Juggernaut checkout named by `JG_UPSTREAM_ROOT`; the
  last two need a real Herdr.

## Requirements: fork-only hook points

The sentinel targets the Juggernaut checkout the homes run today (the fork). It
depends on two hook points that unmodified Kun does not provide:

- `jg-control.sh exit` writes `state/<id>.exit`. The stopped-on-purpose guard
  reads that record; without it a lane exited on purpose can be relaunched after
  a host restart.
- `jg_backend_agent_state` takes four arguments, including the lane's meta and
  task id, which the fork's version uses to classify an unknown Herdr pane.

Running the sentinel on unmodified Kun needs both. Later fork-exit slices own
them.
