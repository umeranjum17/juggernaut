# lead-wake

The lead-wake policy of the fork watcher as an optional feature (fork exit 8: step A and slice 2). A squad lead home with ready backlog work (`jg-tasks-axi.sh ready`) that sits below its lane floor, or has no worker provably working, raises one `check:` wake; the wake is withdrawn when the ready set empties.

- `config/lane-target` is one positive integer, the lane floor (a floor, not a cap). Open lanes are `state/<task>.meta` of kind `ship` or `scout`; the fleet-flow check's `counted` column wins when installed. A squad lead home inherits the primary's value.
- Below the floor: `check: ready work waiting with free lane slots (<open>/<target> open): <ids> - ...`; at or above it, or without a usable target: `check: ready work waiting with no worker working: <ids> - ...`.
- The same set re-raises every `JG_READY_WORK_RESURFACE_SECS` (1800), a new set at once, at the base `JG_HEARTBEAT` without idle backoff. An empty set on a good read withdraws the queued row and keeps the resurface record.
- A stalled lead's drain ring (`squad_lead_ring_to_drain`) names the frozen row and its acknowledgement: `Wake row <seq> is still queued in this home. Run bin/jg-wake-drain.sh ... run the exact WAKE_ACK_REQUIRED command it prints ...`. The lib redefines Kun's function after it, so Kun's two-argument call needs no hook line; the row is the oldest actionable one in the mate's queue.

`bin/jg-lead-wake-lib.sh` keeps the fork's names (`lane_target_value`, `open_lane_count`, `warn_invalid_lane_target_once`, `ready_work_waits_idle`, `record_ready_work_surfaced`, `jg_wake_withdraw`) plus `squad_lead_ring_to_drain`, and adds `lead_wake_tick`; `bin/jg-lead-wake-inherit.sh` appends `lane-target` to `JG_INHERITABLE_CONFIG`. Step B puts three lines in Kun's files; each is a no-op under `set -e` when the feature is absent (Kun behavior):

```bash
# jg-watch.sh, above `while :; do`
[ ! -r "${JG_ADDONS_DIR:-$JG_HOME/projects/juggernaut-addons}/lead-wake/bin/jg-lead-wake-lib.sh" ] || . "${JG_ADDONS_DIR:-$JG_HOME/projects/juggernaut-addons}/lead-wake/bin/jg-lead-wake-lib.sh"
# jg-watch.sh, where the ready-work block was
if declare -F lead_wake_tick >/dev/null; then lead_wake_tick; fi
# jg-config-inherit-lib.sh, below JG_INHERITABLE_CONFIG
[ ! -r "${JG_ADDONS_DIR:-${JG_HOME:-}/projects/juggernaut-addons}/lead-wake/bin/jg-lead-wake-inherit.sh" ] || . "${JG_ADDONS_DIR:-${JG_HOME:-}/projects/juggernaut-addons}/lead-wake/bin/jg-lead-wake-inherit.sh"
```

No install state: remove the checkout to uninstall.

Proof: `JG_TEST_FORK=/path/to/read-only/juggernaut bash lead-wake/tests/lead-wake-e2e.sh` stages step B into a private copy of the fork's `bin/` (`tests/stage-step-b.py`: fork definitions removed, Kun's ring restored, hook lines added) and runs the fork's own lead-wake cases, carried in `tests/jg-lead-wake.test.sh` on the fork's wake harness, through the real watcher: idle lead, lane floor (fleet-flow counted column, malformed row and target, resurface), transient empty, withdraw, full-but-idle and the drain-ring text. Add-on absent: Kun's ring text, no ready-work wake, no stderr. Needs `tasks-axi`; CI runs it.
