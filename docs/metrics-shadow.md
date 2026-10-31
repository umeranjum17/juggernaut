# The host and fleet numbers on Prometheus, in shadow

Migration step 5g.
The heartbeat and the fleet report gather four numbers in shell: load from
`/proc/loadavg`, available memory from `/proc/meminfo`, free disk from `df(1)`,
and fleet shape from the per-home records.
Prometheus with node_exporter is the mature replacement, and the stack report
already measured the block it replaces.
This step proves the scrape reproduces those four numbers before anything
switches.

Nothing switches here.
Both paths run at once, the shell collection stays authoritative, and
`bin/jg-metrics-shadow.sh` writes nothing into any home.

## What runs

- `bin/jg-metrics-shadow.sh start` renders `prometheus.yml` from
  `config/metrics-shadow` and runs two processes: node_exporter on the node
  port, and Prometheus configured by that file alone and set to scrape it.
  The file is the whole configuration, so an operator can read it.
- `sync` starts both if they are not up and then exports the fleet shape.
  `bin/jg-watch.sh` runs one `sync` per poll when the home has
  `config/metrics-shadow`, so both paths really do run at once.
  Off costs one file test.
- The shadow never becomes a dependency: a missing binary or a port that does
  not answer prints `skip: ...` and the shell path behaves exactly as before.
  `parity` is the opposite, because it is an explicit check: a shadow that is
  off, or has no binary to run, fails it rather than skipping it, so a run that
  did not happen is never readable as a green one.
- The two processes keep their bytes outside the home, in
  `${XDG_CACHE_HOME}/jg-metrics-shadow`: the rendered config, the textfile
  bridge, the time-series store, the logs and the pid records.
  A pid record carries the process start time, so `stop` never signals a
  stranger that reused the pid.

## The four numbers

| field | shell path | Prometheus path | tolerance |
| --- | --- | --- | --- |
| load | `/proc/loadavg`, field 1 (`bin/jg-reaper-lib.sh`) | `node_load1` | 1.00 absolute |
| available memory | `/proc/meminfo` `MemAvailable` (`bin/jg-jev-mem-guard.py`, the host-memory gate) | `node_memory_MemAvailable_bytes / 1024` | 2% of the shell value |
| free disk | `df -P` field 4 on the root mount (`bin/jg-tmp-sweep.sh`) | `node_filesystem_avail_bytes{mountpoint="/"}` | 64 MiB |
| fleet shape | `bin/jg-fleet-heartbeat.sh rows` | `jg_fleet_home_*` from the textfile bridge | 0 |

Every tolerance is a sampling gap and never an allowance for a wrong answer: the
shell reads the kernel at one instant and Prometheus serves the scrape that
landed before it, so a field moves between the two reads.
The load tolerance is one whole unit because a one-minute average decays by one
sixtieth of a jump every second.
The disk tolerance is 64 MiB because only a write moves that number.
The fleet-shape tolerance is zero because both sides read the same pinned rows,
so the only thing that comparison can find is a transport defect.

## The bridge

Fleet shape has no exporter to install: it is derived from records this fleet
already writes.
So the bridge runs the shipped collector, `bin/jg-fleet-heartbeat.sh rows`, and
formats those rows into node_exporter's textfile format:

```
jg_fleet_home_working{home="overwatch"} 4
jg_fleet_home_target{home="overwatch"} 4
jg_fleet_home_ready{home="overwatch"} 110
jg_fleet_home_waits{home="overwatch"} 0
jg_fleet_home_beacon_age_seconds{home="overwatch"} 83
jg_fleet_home_verdict{home="overwatch",verdict="MOVING"} 1
```

This is the shape the stack report decided: an exporter for a fleet-specific fact
stays in code and writes textfile metrics, while the numbers the kernel already
publishes come from node_exporter.
No rule is re-implemented, so a switch keeps the 54 lines of bridge and drops
only the shell readers of the host numbers.
A row whose field the collector prints as `-` or `?` exports no sample, and
parity reports that field as skipped rather than as a difference.

## The parity contract

`bin/jg-metrics-shadow.sh parity` reads one instant through both paths and prints
one row per field, with the delta and the verdict:

```
field                      shell              prometheus         delta      verdict
load1                      11.85              11.84              -0.0100    ok
mem_available_kib          41106904           41400164           293260.0000 ok
disk_avail_kib             448752200          448752200          0.0000     ok
fleet_overwatch_working    4                  4                  0.0000     ok
...
metrics shadow parity: homes=1 fields_compared=9 fields_skipped=0 differences=0
```

One instant is why there is no churn accounting.
The run pins the collector's rows first, exports those exact rows, and then waits
for a fleet-shape sample whose own timestamp is later than the write.
A sample from an earlier run can never satisfy that wait, and the instant is
pinned in milliseconds for that reason: an instant query's returned timestamp is
the evaluation time, so the wait reads PromQL's `timestamp()` of the sample
instead.
The comparison then reads the pinned rows against the scraped series, so a lane
that changes while the check runs cannot move either side of it.

A run that compared nothing is not a pass: an empty fleet must never read a green
parity as this switch's evidence, so `parity` fails unless it compared the three
host numbers and at least one shape field per home.

`--corrupt` publishes one tampered sample on the new path alone: the first home's
wait count moves by one in the copy that is exported, while the pinned rows the
shell side is compared against stay true.
Parity must then report that field as a difference, which is what makes a green
run non-vacuous.
The heal exports the true rows again before parity exits, so a replay never
leaves the shadow holding a lie.

### What it does not prove

- Alerting. No rule and no Alertmanager runs here, so the alarm-in-config shape
  the stack report decided, with a `promtool test rules` test per rule, is not
  replayed. What is proven is the scrape those rules would read.
- A switched host. Both processes run beside the shell collection, and the shell
  collection still owns every consequence: no wake, interrupt or guard action
  reads a Prometheus number.
- The memory guard's kill and the tmp sweep's delete. Only the numbers are
  compared; the actions stay in code and are untouched.
- A mount other than the root filesystem. `jg-tmp-sweep.sh` reports a root it is
  told, and parity compares `/`, so a home whose fleet scratch sits on another
  mount is not covered.
- Retention and disk growth over a long run. The store was measured for minutes,
  not days.

## Measured

Measured on the branch that added this, on a 32-core host with 91 GiB of memory.
Nothing below is an estimate.

Shadow path, `bin/jg-metrics-shadow.sh`: 466 lines.

- 74 header, contract and tolerance table.
- 25 for the resolved paths and the two tolerance constants.
- 59 shared vocabulary: the config read, the two gates, the URLs and the wait.
- 85 for the two processes: the rendered config, the start, the pid records with
  their start times, the stop and the status.
- 54 for the bridge: `shape_metrics`, `rows_now`, `export_rows`, `cmd_export`,
  `cmd_sync`.
- 146 for the replay: `query`, `query_label`, `wait_scrape`, `compare`,
  `compare_text`, `corrupt_one`, `field_of` and `cmd_parity`.
- 19 for argument handling.

Of those 466 lines, 146 exist only for the replay, and 28 of those are the
tolerance arithmetic that a switch would delete with the check.

Shell path, the four numbers as they are gathered today, measured with `wc -l`:

- 214 lines of `bin/jg-fleet-heartbeat.sh` for the fleet shape. The bridge keeps
  this file whole, so a switch does not remove it.
- 31 lines of `bin/jg-reaper-lib.sh` for the load alarm:
  `jg_reaper_load_groups` and `jg_reaper_load_alarm`.
- 11 lines of `bin/jg-tmp-sweep.sh` for the disk number: `fs_use`, which is two
  `df -P` calls for space and inodes.
- 320 lines of `bin/jg-jev-mem-guard.py` and 236 lines of `core/host-memory`
  for memory. Only the threshold and the alarm move to a rule; the process
  accounting and the kill stay in code.

So the line win on this step is small: the switch removes about 42 lines of
shell readers and keeps the 214-line collector that feeds the bridge.
The mechanisms are the point. One scrape replaces three shell readers of `/proc`
and `df`; an alert rule with its own `promtool` test replaces an alarm written in
awk; and the numbers gain history, which is what makes a threshold reviewable
instead of a single sample taken at the moment a watcher happened to tick.

Memory cost of running Prometheus on this host, measured from `/proc/<pid>/status`
after the processes settled, with Prometheus 3.6.0 and node_exporter 1.9.1 and
default flags:

| scrape interval | Prometheus | node_exporter | together | CPU, Prometheus | CPU, node_exporter |
| --- | --- | --- | --- | --- | --- |
| 2s | 83.6-88.0 MiB | 21.9-22.4 MiB | 105.5-110.4 MiB | 0.13% of a core | 1.20% of a core |
| 15s | 81.5 MiB | 21.2 MiB | 102.7 MiB | 0.10% of a core | 0.15% of a core |

The stack report measured 35.8-37.1 MiB for Prometheus in a container.
This host measures 88.0 MiB for the same version, and both numbers are real: the
reported figure came from a much smaller container, and a Go process sizes its
heap against the host it runs on.
On this host node_exporter's CPU is the scrape interval, not the exporter:
1.20% of one core at 2s and 0.15% at 15s.

The store held 2,241 series in 1.7 MiB after 25 minutes at a one-hour retention,
so the disk cost is small beside the fleet's own scratch.

For scale, this fleet's own memory guard alerts below 6 GiB of available memory
and this host reported 39-42 GiB available during the measurement, so 110 MiB of
monitoring is not the binding constraint here.

## Replaying a real fleet

```sh
bin/jg-metrics-shadow.sh start
bin/jg-metrics-shadow.sh export
bin/jg-metrics-shadow.sh parity
bin/jg-metrics-shadow.sh parity --corrupt
```

On the home that ran this measurement: 1 home, 9 fields compared, 0 skipped and 0
differences.
The same run with `--corrupt` reported one difference and named
`fleet_overwatch_waits`, and the following run reported none again.

Ten consecutive parity runs on that home measured the sampling gap each tolerance
exists for: load 0.00, memory at most 82.7 MiB (0.2% of the value), disk 0.00, and
no difference in any run.
The largest memory gap seen on this host was 458 MiB, in a window under heavier
load, and one run of the same home measured 385 MiB, which is why the tolerance is
stated as a percentage of the value rather than as a byte count.

## Test

`tests/jg-metrics-shadow-parity.test.sh` starts a throwaway Prometheus and
node_exporter on two free ports and proves the check in both directions: the
rendered config is what Prometheus runs and it scrapes the shadow's own exporter,
the bridge carries the shipped collector's six shape series, parity is green with
9 fields compared and 0 differences, one tampered sample on the new path fails it
and names the field, the heal restores it, a parity that did not run exits
non-zero, and `stop` leaves no listener behind.
The test gate-skips when `prometheus` or `node_exporter` is missing; set
`JG_PROMETHEUS_BIN` and `JG_NODE_EXPORTER_BIN` to pin them.
