#!/usr/bin/env bash
# Real watcher/drain journey for placeholder-date pauses; the terminal API is a fixture.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/wake-helpers.sh
. "$ROOT/tests/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-wait-timers)
# The status classifier is Go, built on first use into the home's own state directory
# (bin/jg-classify.sh), and every fixture here has a fresh state directory. A cold build
# outlasts JG_WAIT_ALERT_SECS, so the arming cycle would age the wait past its owner alert
# and the journey's own owner assertions would fire inside it. Build the classifier once
# here and point every cycle at it. Every cycle also gets a Go whose build is slow, so a
# fixture that ever reaches a cold build again fails here instead of only on a slow runner.
if command -v "${JG_CLASSIFY_GO:-go}" >/dev/null 2>&1; then
  JG_CLASSIFY_BIN="$TMP_ROOT/classify/jg-classify" "$ROOT/bin/jg-classify.sh" is-paused 'paused: warm' >/dev/null 2>&1 || :
  [ -x "$TMP_ROOT/classify/jg-classify" ] || { echo "wait-timers journey: the classifier did not build" >&2; exit 1; }
  export JG_CLASSIFY_BIN="$TMP_ROOT/classify/jg-classify"
  printf '#!/bin/sh\nsleep 4\nexec %s "$@"\n' "$(command -v "${JG_CLASSIFY_GO:-go}")" > "$TMP_ROOT/slow-go"
  chmod 0755 "$TMP_ROOT/slow-go"
  export JG_CLASSIFY_GO="$TMP_ROOT/slow-go"
fi
# The window inventory (bin/jg-watch-core.sh) is a second Go command, built on first use into
# a cache under HOME, and every cycle here has a fresh HOME. Build it once too, point every
# cycle at it, and give it the same slow Go so a cold build fails here and not on a runner.
if command -v "${JG_WATCH_CORE_GO:-go}" >/dev/null 2>&1; then
  JG_WATCH_CORE_BIN="$TMP_ROOT/watch-core/jg-watch-core" "$ROOT/bin/jg-watch-core.sh" >/dev/null 2>&1 || :
  [ -x "$TMP_ROOT/watch-core/jg-watch-core" ] || { echo "wait-timers journey: the window inventory did not build" >&2; exit 1; }
  export JG_WATCH_CORE_BIN="$TMP_ROOT/watch-core/jg-watch-core"
  export JG_WATCH_CORE_GO="$TMP_ROOT/slow-go"
fi
WATCH="$ROOT/bin/jg-watch.sh"
DRAIN="$ROOT/bin/jg-wake-drain.sh"

cycle() {
  local rc=0 seq gen
  env HOME="$dir/home" XDG_CONFIG_HOME="$dir/home/config" TMPDIR="$dir/tmp" \
    PATH="$dir/fakebin:$PATH" JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" \
    JG_CONFIG_OVERRIDE="$dir/config" JG_POLL=1 JG_SIGNAL_GRACE=1 \
    JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 JG_HOME_SUMMARY_INTERVAL=999999 \
    JG_SQUAD_LEAD_LIVENESS_SECS=99999999 JG_BUSY_TURN_MAX_SECS=999999 \
    JG_STALE_ESCALATE_SECS=999999 JG_WAIT_ALERT_SECS=2 JG_WAIT_ESCALATE_SECS=4 JG_WAIT_CARD_SECS=999999 \
    "$WATCH" > "$dir/out" 2> "$dir/err" &
  pid=$!
  wait_for_exit "$pid" 70 || rc=$?
  case "$rc" in 0|124) ;; *) fail "watcher failed: $(cat "$dir/err")" ;; esac
  cat "$dir/out" >> "$dir/events"
  JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" "$DRAIN" > "$dir/drain" 2> "$dir/ack"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$dir/ack")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$dir/ack")
  [ -z "$seq" ] || JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" >/dev/null
}

# Arms the lane's episode beside a second lane whose status moves on once the episode is
# recorded. That status line is a routine row that waits for the digest, so it does not
# end the arming cycle: the cycle runs to its first urgent wake, and on a loaded host that
# is the episode's own owner alert once the alert threshold has passed.
arm_episode() {  # <dir>
  printf 'kind=ship\nbackend=tmux\nwindow=fake:2\n' > "$1/state/lane-b.meta"
  printf 'working: building\n' > "$1/state/lane-b.status"
  prime_status_seen "$1/state" "$1/state/lane-b.status"
  (
    i=0
    while [ ! -e "$1/state/.waiting-timers/lane" ] && [ "$i" -lt 100 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    printf 'working: step two\n' >> "$1/state/lane-b.status"
  ) &
  cycle
  wait
}

# Rewinds the lane's episode to an aged wait that nobody has been told about yet, and
# drops the arming cycle's wakes along with the delivery that rewrite erases, so every
# count after it starts from that state.
age_episode() {  # <dir> [lane]
  local file="$1/state/.waiting-timers/${2:-lane}" sig since key
  IFS=$'\t' read -r sig since _ _ key _ < "$file"
  printf '%s\t%s\t0\t0\t%s\t0\n' "$sig" "$((since - 900))" "$key" > "$file"
  : > "$1/events"
}

# A placeholder date is no deadline: the real watcher must recheck it after 30 minutes.
dir=$(make_case placeholder-pause)
mkdir -p "$dir/home/config" "$dir/tmp" "$dir/config"
printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$dir/state/lane.meta"
printf 'paused: waiting until 2026-12-31\n' > "$dir/state/lane.status"
prime_status_seen "$dir/state" "$dir/state/lane.status"
arm_episode "$dir"
[ -e "$dir/state/.waiting-timers/lane" ] || fail 'placeholder pause armed no episode'
IFS=$'\t' read -r sig since _owner _parent key _misses < "$dir/state/.waiting-timers/lane"
printf '%s\t%s\t0\t0\t%s\t0\n' "$sig" "$(( $(date +%s) - 1801 ))" "$key" > "$dir/state/.waiting-timers/lane"
: > "$dir/events"
cycle
grep -q 'check: waiting-state lane (paused, observed .*level=owner' "$dir/events" || fail 'placeholder pause did not recheck at 30 minutes'
pass 'placeholder pause rechecks after 30 minutes'


# An unchanged placeholder stays on the 30-minute cadence.
IFS=$'\t' read -r sig since _owner parent key misses card _last < "$dir/state/.waiting-timers/lane"
old=$(( $(date +%s) - 1801 ))
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sig" "$since" "$old" "$parent" "$key" "$misses" "$card" "$old" > "$dir/state/.waiting-timers/lane"
: > "$dir/events"
cycle
grep -q 'waiting-state lane (paused, observed .*still open' "$dir/events" || fail 'placeholder pause did not recheck again after 30 minutes'

# A real future deadline stays quiet.
printf 'paused: waiting until 2099-12-31T00:00Z\n' > "$dir/state/lane.status"
cycle
cycle
[ ! -e "$dir/state/.waiting-timers/lane" ] || fail 'real future deadline retained a timer episode'
pass 'real future deadline remains quiet'
