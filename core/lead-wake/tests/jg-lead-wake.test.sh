#!/usr/bin/env bash
# The fork's lead-wake cases (idle lead, lane floor, transient
# empty, withdraw, full-but-idle, drain ring), carried so the fork
# can drop them. lead-wake-e2e.sh runs this from a staged fork's tests/ on the fork's wake harness,
# which Kun's suites keep. Needs tasks-axi. `ring` runs only the ring case; RING_TEXT sets its steer.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$here/wake-helpers.sh"
# shellcheck source=/dev/null
. "$here/lead-wake-harness.sh"
# shellcheck disable=SC2034 # WATCH and TMP_ROOT are read by the borrowed fork harness.
WATCH="$ROOT/bin/jg-watch.sh" DRAIN="$ROOT/bin/jg-wake-drain.sh" TASKS="$ROOT/bin/jg-tasks-axi.sh" TMP_ROOT=$(jg_test_tmproot jg-lead-wake-tests)
WORKING='state: working · source: run-step · validating (running)'
RING_TEXT=${RING_TEXT:-Wake row 7 is still queued in this home. Run bin/jg-wake-drain.sh and read its whole output, handle what it presents, then run the exact WAKE_ACK_REQUIRED command it prints, which is what removes the row. Then resume idle supervision.}

newhome() {  # <name>: a fresh squad_lead home; sets dir state fakebin out
  dir=$(make_case "$1"); state=$dir/state; fakebin=$dir/fakebin; out=$dir/watch.out
  mkdir -p "$dir/data" "$dir/config"; printf '%s\n' "$1" > "$dir/.jg-squad-lead-home"
  # These cases add bare fixture items for wake behavior, so this home opts out of
  # the strict backlog intake that slice 3 turned on by default.
  : > "$dir/config/backlog-intake-loose"
}
tasks() { JG_HOME="$dir" "$TASKS" "$@" >/dev/null || fail "fixture: tasks $*"; }
ack() { ack_stopped_cycle "$state" >/dev/null || fail "could not acknowledge the cycle"; }
drained() { JG_STATE_OVERRIDE="$state" "$DRAIN" 2>/dev/null; }
# wake <reason> [env...]: one watcher run exits on exactly <reason>.
wake() {
  local want=$1 pid; shift
  watch_bg "$state" "$fakebin" "$out" env JG_HOME="$dir" JG_HEARTBEAT=1 "$@"; pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "no wake, want: $want"; }
  grep -Fx "$want" "$out" >/dev/null || fail "want '$want', got: $(cat "$out")"
}
# absorbed <failure> [env...]: one heartbeat is absorbed with nothing printed.
absorbed() {
  local why=$1 pid i=0; shift
  rm -f "$state/.heartbeat-streak" "$state/.last-heartbeat"
  watch_bg "$state" "$fakebin" "$out" env JG_HOME="$dir" JG_HEARTBEAT=1 "$@"; pid=$!
  until [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ]; do
    kill -0 "$pid" 2>/dev/null && [ "$i" -lt 200 ] || { reap "$pid"; fail "$why: $(cat "$out")"; }
    sleep 0.1; i=$((i + 1))
  done
  reap "$pid"
  [ ! -s "$out" ] || fail "$why: $(cat "$out")"
  ack
}
# cycle <failure>: one handling-successor poll cycle with a due ready-work check prints nothing.
cycle() {
  local pid
  rm -f "$state/.last-ready-work-check"; : > "$out"
  watch_bg "$state" "$fakebin" "$out" env JG_HOME="$dir" JG_HEARTBEAT=1 JG_WATCH_HANDLING_SUCCESSOR=1; pid=$!
  wait_poll_cycle "$state" "$pid" 300 || { reap "$pid"; fail "$1: the cycle did not complete: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "$1: $(cat "$out")"
}

test_idle_lead() {
  newhome sm-ready-1
  tasks add beta-two "second ready item"; tasks add alpha-one "first ready item"
  tasks add gamma "blocked item" --blocked-by alpha-one
  tasks add held-one "held item"; tasks hold held-one --reason "waiting for approval"
  tasks add future-one "future item"; tasks hold future-one --reason "scheduled later" --until 2099-01-01 --kind future
  # A backed-off idle heartbeat still reads ready work at the base cadence.
  echo 12 > "$state/.heartbeat-streak"; touch "$state/.last-heartbeat"
  wake "check: ready work waiting with no worker working: alpha-one beta-two - start each or record why it waits"
  drained | grep -F "$(printf '\tcheck\t')" >/dev/null || fail "the ready-work wake was not queued as a check row"
  ack
  absorbed "the same ready set woke the lead again"
  tasks add delta "third ready item"
  printf 'window=test:jg-busy\nkind=ship\n' > "$state/busy.meta"
  absorbed "ready work woke a lead whose worker is working" JG_FAKE_TMUX_WINDOW=test:jg-busy JG_FAKE_CREW_STATE="$WORKING"
  pass "an idle lead with ready work is woken once per ready set, and never while a worker is working"
}
test_lane_floor() {
  local spare='kind=squad_lead\nmode=squad_lead\n' want flow lanes
  newhome sm-lane-floor
  # Four panes stay open; the two spare endpoints are squad_leads, which are not lanes.
  lanes=(JG_FAKE_TMUX_WINDOWS="$(printf 'jg-busyone\njg-busytwo\njg-busythree\njg-busyfour')" JG_FAKE_CREW_STATE="$WORKING")
  tasks add alpha-one "first ready item"
  printf '4\n' > "$dir/config/lane-target"
  printf 'window=test:jg-busyone\nkind=ship\n' > "$state/busyone.meta"; printf 'window=test:jg-busytwo\nkind=scout\n' > "$state/busytwo.meta"
  printf 'window=test:jg-busythree\n%b' "$spare" > "$state/busythree.meta"; printf 'window=test:jg-busyfour\n%b' "$spare" > "$state/busyfour.meta"
  want="check: ready work waiting with free lane slots (2/4 open): alpha-one - start the top ready item now, or record why it waits"
  wake "$want" "${lanes[@]}"; ack
  absorbed "the same lane-floor condition woke again inside the resurface window" "${lanes[@]}"
  printf 'window=test:jg-busythree\nkind=ship\n' > "$state/busythree.meta"; printf 'window=test:jg-busyfour\nkind=ship\n' > "$state/busyfour.meta"
  absorbed "a home at its lane floor was woken" "${lanes[@]}"
  # The installed fleet-flow check's counted column (2) wins over the meta count (4).
  flow=$dir/xdg/jg-fleet-flow/jg-flow-check.sh; mkdir -p "${flow%/*}"
  printf '#!/usr/bin/env bash\nprintf "sm-lane-floor\\t4\\t2\\t1\\t0\\t0\\t0\\t2\\t0\\n"\n' > "$flow"; chmod +x "$flow"
  rm -f "$state/.heartbeat-streak" "$state/.last-heartbeat" "$state/.ready-work-surfaced"
  wake "$want" XDG_DATA_HOME="$dir/xdg" "${lanes[@]}"; ack
  # A malformed row is not read as a number: the meta count (at the floor) stands.
  printf '#!/usr/bin/env bash\necho "not a summary row"\n' > "$flow"
  rm -f "$state/.ready-work-surfaced"
  absorbed "a malformed flow check row fired the lane-floor wake" XDG_DATA_HOME="$dir/xdg" "${lanes[@]}"
  # Still holding after the resurface window, the same condition re-raises.
  printf 'window=test:jg-busythree\n%b' "$spare" > "$state/busythree.meta"; printf 'window=test:jg-busyfour\n%b' "$spare" > "$state/busyfour.meta"
  rm -f "$state/.heartbeat-streak" "$state/.last-heartbeat"; sleep 2
  wake "$want" JG_READY_WORK_RESURFACE_SECS=1 "${lanes[@]}"; ack
  # A malformed target is reported and falls back to the no-worker-working rule.
  printf 'four\n' > "$dir/config/lane-target"
  absorbed "a malformed lane-target read as a number and fired" "${lanes[@]}"
  grep -F 'lane-target is not a positive integer' "$state/.watch-triage.log" >/dev/null \
    || fail "a malformed lane-target was not reported"
  pass "a home under its lane floor wakes with free lane slots, stays quiet at the floor, and re-raises while held"
}
test_transient_empty() {
  local before
  newhome sm-ready-empty
  printf '4\n' > "$dir/config/lane-target"
  tasks add alpha-one "first ready item"; tasks add beta-two "second ready item"; tasks add gamma-three "third ready item"
  wake "check: ready work waiting with free lane slots (0/4 open): alpha-one beta-two gamma-three - start the top ready item now, or record why it waits"
  before=$(cat "$state/.ready-work-surfaced") || fail "the check did not record its surfacing"
  ack
  tasks hold alpha-one --reason wait; tasks hold beta-two --reason wait; tasks hold gamma-three --reason wait
  cycle "an empty ready set still woke"
  [ "$(cat "$state/.ready-work-surfaced" 2>/dev/null)" = "$before" ] || fail "the empty ready set erased the resurface record"
  ack_stopped_cycle "$state" >/dev/null 2>&1 || true
  tasks unhold alpha-one; tasks unhold beta-two; tasks unhold gamma-three
  cycle "the identical ready-work check replayed inside the resurface window"
  [ "$(cat "$state/.ready-work-surfaced" 2>/dev/null)" = "$before" ] || fail "the absorbed set re-recorded its surfacing"
  pass "a transient empty ready set does not replay the ready-work notification inside the window"
}
test_withdraw() {
  local row
  row=$(printf '\tcheck\tready-work\t')
  newhome sm-ready-withdraw
  printf '4\n' > "$dir/config/lane-target"
  tasks add alpha-one "first ready item"; tasks add beta-two "second ready item"
  wake "check: ready work waiting with free lane slots (0/4 open): alpha-one beta-two - start the top ready item now, or record why it waits"
  grep -F "$row" "$state/.wake-queue" >/dev/null || fail "the ready-work row was not queued"
  drained | grep -F alpha-one >/dev/null || fail "the drain did not present the unacknowledged ready row"
  tasks hold alpha-one --reason wait; tasks hold beta-two --reason wait
  cycle "an empty ready set still woke"
  ! grep -F "$row" "$state/.wake-queue" >/dev/null 2>&1 || fail "the stale ready-work row was not withdrawn"
  ! drained | grep -F 'ready work waiting' >/dev/null || fail "the drain re-presented the withdrawn row"
  ack_stopped_cycle "$state" >/dev/null 2>&1 || true
  tasks unhold alpha-one
  rm -f "$state/.last-ready-work-check"
  wake "check: ready work waiting with free lane slots (0/4 open): alpha-one - start the top ready item now, or record why it waits" \
    JG_WATCH_HANDLING_SUCCESSOR=1
  ! drained | grep -F beta-two >/dev/null || fail "the drain presented a held item"
  pass "a stale ready-work row is withdrawn and the check never names a held item"
}
test_full_idle() {
  local i
  newhome sm-full-idle
  tasks add alpha-one "first ready item"
  printf '4\n' > "$dir/config/lane-target"
  for i in 1 2 3 4; do printf 'kind=ship\n' > "$state/lane$i.meta"; done
  wake "check: ready work waiting with no worker working: alpha-one - start each or record why it waits" \
    JG_FAKE_CREW_STATE='state: blocked · source: status-log · parked on a sibling lane'
  ack
  pass "a home with every lane slot open but no worker working is woken"
}

# leg <child-queue-the-ring-drains> <leg> <mode> [arg...]: one stall-watch leg at the fake clock.
leg() {
  PATH="$fakebin:$PATH" JG_FAKE_NOW_FILE="$dir/now" JG_HOME="$dir" JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$state" \
    JG_FAKE_TMUX_SENT="$dir/sent" JG_FAKE_CHILD_WAKE_QUEUE=$1 JG_SQUAD_LEAD_WAKE_STALL_SECS=1 JG_POLL=1 JG_SIGNAL_GRACE=0 \
    JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 squad_lead_stall_watch_leg "$dir" "${@:2}"
}
# A proven-idle mate with a frozen row is rung once; the steer names the row and its ack.
test_drain_ring() {
  local sub inbox_rec steer
  dir=$(make_case squad-lead-drain-ring); state=$dir/state; sub=$dir/squad_lead; fakebin=$dir/fakebin
  mkdir -p "$sub/state"
  printf 'mate\n' > "$sub/.jg-squad-lead-home"
  printf 'window=juggernaut:jg-mate\nkind=squad_lead\nharness=claude\nbackend=tmux\nhome=%s\n' "$sub" > "$state/mate.meta"
  printf '100\t7\tcheck\trouted\tcheck: routed row\n' > "$sub/state/.wake-queue"
  install_squad_lead_alive_tmux "$fakebin"
  install_squad_lead_stall_date "$fakebin"
  "$ROOT/bin/jg-busy-event.sh" arm "$state" mate >/dev/null || fail "could not arm the mate's busy contract"
  "$ROOT/bin/jg-busy-event.sh" apply "$state" mate idle --current-gen --source claude-hook --event stop >/dev/null \
    || fail "could not mark the mate idle"
  printf '1000\n' > "$dir/now"
  leg '' first progress mate "$(printf '1000\t100-7')"
  printf '1002\n' > "$dir/now"
  leg "$sub/state/.wake-queue" ring drained mate "$sub/state/.wake-queue"
  ! grep -F 'squad_lead wake-loop stalled' "$dir/watch-ring.out" >/dev/null || fail "a rung idle mate still alarmed"
  [ "$(grep -c -F '[ENTER]' "$dir/sent" 2>/dev/null || true)" = 1 ] || fail "the idle mate was not rung exactly once"
  for inbox_rec in "$state/mate.inbox/"*.msg; do break; done
  [ -f "$inbox_rec" ] || fail "the ring wrote no drain steer"
  steer=$(sed '1,/^--$/d' "$inbox_rec" | "$ROOT/bin/jg-operational-input.sh" body)
  [[ $steer =~ ^delivery=[0-9a-f]{16}\ (.*)$ ]] || fail "the drain steer carries no delivery id: $steer"
  [ "${BASH_REMATCH[1]}" = "$RING_TEXT" ] || fail "the ring wrote the wrong drain instruction: $steer"
  pass "a proven-idle mate is rung once to drain, with the steer: ${RING_TEXT%%.*}"
}

if [ "${1:-}" = ring ]; then test_drain_ring; exit 0; fi
test_idle_lead
test_lane_floor
test_transient_empty
test_withdraw
test_full_idle
test_drain_ring
