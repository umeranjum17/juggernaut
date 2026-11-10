#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=/dev/null
. "$ROOT/core/lib/beads-test-env.sh"
TMUX_BIN=$(command -v tmux) || exit 1
world=$(mktemp -d "${TMPDIR:-/tmp}/jg-wait-e2e.XXXXXX")
sock="jg-wait-e2e-$$"
watch_pid=''
cleanup() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL: real tmux wait journey (exit %s)\n' "$rc"
    for file in out err events drain ack hold-identity state/.waiting-timers/jg-held-lane parent/state/lead.status; do
      [ ! -f "$world/$file" ] || { printf '\n%s:\n' "$file"; cat "$world/$file"; }
    done
  fi
  [ -z "$watch_pid" ] || kill "$watch_pid" 2>/dev/null || :
  [ -z "$watch_pid" ] || wait "$watch_pid" 2>/dev/null || :
  "$TMUX_BIN" -L "$sock" kill-server 2>/dev/null || :
  rm -rf -- "$world" "$world-store"
}
trap cleanup EXIT
mkdir -p "$world"/{state,data,config,home,tmp,fakebin,parent/state}
printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$TMUX_BIN" "$sock" > "$world/fakebin/tmux"
chmod +x "$world/fakebin/tmux"
export HOME="$world/home" XDG_CONFIG_HOME="$world/home/config" TMPDIR="$world/tmp"
export PATH="$world/fakebin:$PATH" JG_HOME="$world" JG_STATE_OVERRIDE="$world/state" JG_DATA_OVERRIDE="$world/data" JG_CONFIG_OVERRIDE="$world/config"
export JG_ROOT_OVERRIDE="$world" JG_TMUX_SESSION=juggernaut JG_SESSION=juggernaut
printf 'tmux\n' > "$world/config/backend"
printf 'lead\n' > "$world/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$world/parent" > "$world/.jg-squad-lead-parent"
core_beads_home "$ROOT" "$world"
(cd "$world" && jg-backlog.sh add jg-held-lane 'deliberately paused lane')
tmux new-session -d -s juggernaut -n jg-held-lane 'sleep 300'
printf 'window=juggernaut:jg-held-lane\nkind=ship\nharness=pi\nbackend=tmux\nworktree=%s\n' "$world" > "$world/state/jg-held-lane.meta"
cycle() {
  JG_POLL=1 JG_SIGNAL_GRACE=1 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 \
    JG_HOME_SUMMARY_INTERVAL=999999 JG_SQUAD_LEAD_LIVENESS_SECS=99999999 \
    JG_WAIT_ALERT_SECS=2 JG_WAIT_ESCALATE_SECS=4 \
    bash "$ROOT/bin/jg-watch.sh" > "$world/out" 2> "$world/err" &
  watch_pid=$!
  for _unused in 1 2 3 4 5 6 7 8; do
    kill -0 "$watch_pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$watch_pid" 2>/dev/null; then
    kill "$watch_pid"
    wait "$watch_pid" || :
  else
    wait "$watch_pid" || { cat "$world/err"; exit 1; }
  fi
  watch_pid=''
  cat "$world/out" >> "$world/events"
  bash "$ROOT/bin/jg-wake-drain.sh" > "$world/drain" 2> "$world/ack"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$world/ack")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$world/ack")
  [ -z "$seq" ] || bash "$ROOT/bin/jg-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null
}
printf 'paused: validation until 2099-01-01T00:00Z\n' > "$world/state/jg-held-lane.status"
cycle
[ ! -e "$world/state/.waiting-timers/jg-held-lane" ] || { echo 'future pause admitted'; exit 1; }
! grep -q 'waiting-state' "$world/events" || exit 1
printf 'paused: validation until 2000-01-01T00:00Z\n' >> "$world/state/jg-held-lane.status"
cycle
cycle
# The signal scan runs before the timer tick, so one cycle consumes the
# appended pause line's signal before the episode arms; the arming cycle's
# poll must also leave the owner unalerted even though JG_WAIT_ALERT_SECS=2,
# because a declared pause rechecks at JG_PAUSE_RESURFACE_SECS (default 4 h).
[ -f "$world/state/.waiting-timers/jg-held-lane" ] || { echo 'due pause not armed'; exit 1; }
IFS=$'\t' read -r _sig _since owner _parent _key < "$world/state/.waiting-timers/jg-held-lane"
[ "$owner" = 0 ] || { echo 'pause alerted at the owner-alert threshold'; exit 1; }
IFS=$'\t' read -r sig since _owner _parent key _misses < "$world/state/.waiting-timers/jg-held-lane"
printf '%s\t%s\t0\t0\t%s\t0\n' "$sig" "$((since - 15000))" "$key" > "$world/state/.waiting-timers/jg-held-lane"
cycle
grep -q 'waiting-state jg-held-lane (paused' "$world/events" || exit 1
[ ! -s "$world/parent/state/lead.status" ] || { echo 'pause escalated to Main'; exit 1; }
bash "$ROOT/bin/jg-captain-hold.sh" hold jg-held-lane --reason test
bash "$ROOT/bin/jg-captain-hold.sh" open jg-held-lane --identity > "$world/hold-identity"
[ -s "$world/hold-identity" ] || exit 1
: > "$world/events"
for _round in 1 2 3; do cycle; sleep 2; done
# The expired pause line still reaches the core stale heuristic, which is unchanged
# from the base, so only the timers' own alarms must stay silent for a held lane.
! grep -E 'waiting-state|stopped|possible wedge' "$world/events" || { echo 'held item alarmed'; exit 1; }
[ ! -e "$world/state/.waiting-timers/jg-held-lane" ] || exit 1
! grep -q 'waiting-timer-overdue' "$world/parent/state/lead.status" || exit 1
# Main's relay of an overdue worker report to its lead: a lead in a turn is never
# interrupted, and its steer waits in its inbox; an idle
# lead gets the steer and the doorbell at once. The lead pane records every key.
rm -f "$world/.jg-squad-lead-home" "$world/.jg-squad-lead-parent"
# A pane whose foreground process is an agent named claude; it records every byte typed at it.
cp "$(command -v bash)" "$world/fakebin/claude"
# shellcheck disable=SC2016 # the pane script expands its own variables
printf 'stty raw -echo\nwhile IFS= read -rsn1 c; do printf "%%s" "${c:-<Enter>}" >> "$1"; done\n' > "$world/agent.sh"
lead_pane() {  # <lead> <busy|idle>
  rm -f "$world/keys-$1"
  tmux new-window -d -t juggernaut -n "jg-$1" "$world/fakebin/claude $world/agent.sh $world/keys-$1"
  printf 'kind=squad_lead\nmode=squad_lead\nbackend=tmux\nwindow=juggernaut:jg-%s\nharness=claude\nhome=%s\nworktree=%s\nproject=lead\n' "$1" "$world/lead-home-$1" "$world" > "$world/state/$1.meta"
  bash "$ROOT/bin/jg-busy-event.sh" arm "$world/state" "$1" --state "$2" --source claude-hook --event stop >/dev/null
  since=$(($(date +%s) - 5))
  printf 'blocked [key=waiting-timer-0000aaaa-w1-g%s-q]: waiting-timer-overdue: w1 (needs-decision key=q, observed 5s, since=%s); owning lead has not cleared the wait; Main must unblock or steer the lead; source=[needs-decision [key=q]: pick a database]\n' "$since" "$since" > "$world/state/$1.status"
}
steered() { grep -l 'Your worker w1 has been stuck' "$world/state/$1.inbox"/*.msg 2>/dev/null | head -n 1; }
lead_pane busy-lead busy
cycle
cycle
[ -n "$(steered busy-lead)" ] || { echo 'busy lead was not steered'; exit 1; }
sleep 1
# jg-send's own first bell is a line queued in the composer; an interrupt is an Escape key.
! grep -q "$(printf '\033')" "$world/keys-busy-lead" 2>/dev/null || { echo 'busy lead was interrupted'; cat -v "$world/keys-busy-lead"; exit 1; }
lead_pane idle-lead idle
cycle
cycle
sleep 1
[ -n "$(steered idle-lead)" ] || { echo 'idle lead was not steered'; exit 1; }
grep -q 'inbox' "$world/keys-idle-lead" || { echo 'idle lead was not rung at once'; exit 1; }
! grep -q "$(printf '\033')" "$world/keys-idle-lead" || { echo 'idle lead was interrupted'; exit 1; }
printf 'lead in a turn: steer in its inbox (%s), keys typed at its pane: %s\n' "$(basename "$(steered busy-lead)")" "$(cat -v "$world/keys-busy-lead")"
printf 'idle lead: steer in its inbox (%s), keys typed at its pane: %s\n' "$(basename "$(steered idle-lead)")" "$(cat -v "$world/keys-idle-lead")"
echo 'PASS: real tmux watcher honours pause deadline, owner-only pause and active captain hold, and relays to a busy lead without an interrupt'
