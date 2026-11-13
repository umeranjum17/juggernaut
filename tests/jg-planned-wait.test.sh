#!/usr/bin/env bash
# A wait on a known future event (a change held for the next release branch) names when it clears
# with `until <UTC time>`. It must raise no wake now and no re-ping while that time is ahead, for a
# `paused:` line and for a `blocked:` line alike; a blocked wait that names no clearing condition
# still climbs to its owner. Real watcher and drain cycles over a copy of this checkout; only the
# terminal, the board and the steer endpoints are recorders.
# This file is also the done-done journey planned-wait (the journey runs it directly).
set -eu

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-planned-wait)
FORK="$TMP_ROOT/fork"
mkdir -p "$FORK"
cp -a "$ROOT/bin" "$ROOT/core" "$FORK/"
# The steer and interrupt endpoints record their calls in the calling home.
for f in jg-send.sh jg-control.sh; do
  # shellcheck disable=SC2016 # the recorder expands its own arguments when run
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >> "$JG_HOME/sent"\n' "${f%.sh}" > "$FORK/bin/$f"
done

# A home with a recorded terminal (fake:<n> panes listed in $JG_FAKE_PANES,
# each showing $h/panes/<n>, an agent in the foreground) and a recording board.
home() {  # <name> -> home path
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state" "$h/config" "$h/home" "$h/tmp" "$h/fakebin" "$h/panes"
  : > "$h/config/backlog-intake-loose"
  jg_test_track_watcher_state "$h/state"
  cat > "$h/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
t=; prev=
for a in "$@"; do [ "$prev" = -t ] && t=$a; prev=$a; done
listed() { case " ${JG_FAKE_PANES:-} " in *" ${1#fake:} "*) return 0 ;; esac; return 1; }
case "${1:-}" in
  list-windows) for p in ${JG_FAKE_PANES:-}; do printf '%s\n' "$p"; done ;;
  capture-pane) listed "$t" || exit 1; cat "$JG_HOME/panes/${t#fake:}" 2>/dev/null || printf 'all quiet\n> \n' ;;
  display-message)
    listed "$t" || exit 1
    case "$*" in *pane_tty*) printf '/dev/pts/fake\n' ;; *pane_current_command*) printf 'claude\n' ;; *) printf '%%1\n' ;; esac ;;
  *) exit 1 ;;
esac
SH
  cat > "$h/fakebin/ps" <<'SH'
#!/usr/bin/env bash
case " $* " in *" -t "*) printf '  100   100   100 claude\n'; exit 0 ;; esac
for p in /bin/ps /usr/bin/ps; do [ ! -x "$p" ] || exec "$p" "$@"; done
exit 1
SH
  cat > "$h/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
log="$JG_HOME/cards"
case "${1:-}" in
  raise)
    key=; prev=
    for a in "$@"; do [ "$prev" = --key ] && key=$a; prev=$a; done
    printf 'raise %s\n' "$*" >> "$log"
    grep -Fxq "$key" "$log.open" 2>/dev/null || printf '%s\n' "$key" >> "$log.open" ;;
  list) printf '{"decisions":[%s]}\n' "$(sed 's/.*/{"key":"&"}/' "$log.open" 2>/dev/null | paste -sd, -)" ;;
  dismiss)
    printf 'dismiss %s\n' "$2" >> "$log"
    { grep -Fxv "$2" "$log.open" 2>/dev/null || true; } > "$log.tmp"; mv "$log.tmp" "$log.open" ;;
esac
SH
  # The forge read: prints the recorded answer (state, draft, merge state, head) or fails.
  cat > "$h/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$JG_HOME/gh.log"
[ -s "$JG_HOME/gh-answer" ] || exit 1
cat "$JG_HOME/gh-answer"
SH
  chmod +x "$h/fakebin/"*
  printf '%s\n' "$h"
}

# One watcher cycle; Main drains and acknowledges its wakes unless absent.
# While Main is absent the next cycle is the successor the arm path starts
# over its unread wakes, which keeps supervising instead of re-announcing them.
#
# A cycle keeps the four-second budget it always had, minus its one hard edge: it
# never stops inside a scan. A scan that overruns the budget (a loaded runner) is
# allowed to finish, so the wake it was about to report is not lost with it. The
# watcher stamps its liveness beacon after each complete scan, so the wait ends at
# a scan boundary instead of in the middle of one.
cycle() {  # <home> [absent]
  local h=$1 rc=0 seq gen pid successor=0 mark
  [ "${2:-}" != absent ] || successor=1
  mark="$h/tmp/cycle-mark"
  touch "$mark"
  env -u JG_TASK_ID JG_WATCH_HANDLING_SUCCESSOR="$successor" HOME="$h/home" TMPDIR="$h/tmp" PATH="$h/fakebin:$PATH" \
    JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_CONFIG_OVERRIDE="$h/config" \
    JG_POLL=1 JG_SIGNAL_GRACE=1 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 JG_HOME_SUMMARY_INTERVAL=999999 \
    JG_SQUAD_LEAD_LIVENESS_SECS="${LIVENESS:-99999999}" JG_BUSY_TURN_MAX_SECS=999999 JG_STALE_ESCALATE_SECS=999999 \
    JG_SQUAD_LEAD_WAKE_STALL_SECS=999999 JG_WAIT_ALERT_SECS=2 JG_WAIT_ESCALATE_SECS=4 JG_WAIT_CARD_SECS="${CARD_SECS:-6}" \
    JG_READY_STALL_POLL_SECS=0 JG_GREEN_PR_POLL_SECS=0 \
    JG_PROMPT_REALERT_SECS=900 JG_FAKE_PANES="${PANES:-}" "$FORK/bin/jg-watch.sh" > "$h/out" 2> "$h/err" &
  pid=$!
  wait_for_scan "$pid" "$h/state" "$mark" "${CYCLE_POLLS:-40}" "${CYCLE_POLLS_MAX:-600}" || rc=$?
  case "$rc" in 0|124) ;; *) fail "watcher failed ($rc): $(cat "$h/err")" ;; esac
  cat "$h/out" >> "$h/events"
  [ "${2:-}" != absent ] || return 0
  JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" "$FORK/bin/jg-wake-drain.sh" > "$h/drain" 2> "$h/ack"
  # The wake queue is the delivery; the line the watcher prints is its doorbell.
  # A cycle that is stopped between queueing a wake and printing it (the stop
  # lands inside a scan on a loaded runner) still delivered it: Main's drain holds
  # the row. Count every drained wake as delivered to Main, once.
  awk -F '\t' 'NF >= 5 && $1 ~ /^[0-9]+$/ && $3 ~ /^(signal|stale|check|heartbeat)$/ { print $5 }' "$h/drain" \
    | while IFS= read -r line; do grep -Fxq -- "$line" "$h/events" || printf '%s\n' "$line" >> "$h/events"; done
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$h/ack")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$h/ack")
  [ -z "$seq" ] || JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" "$FORK/bin/jg-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null
}

# A cycle stops at its first wake, so a home holding two open waits can report
# the other one first. Repeat bounded cycles until the wanted line is visible;
# the caller's assertion still reports the miss with its full evidence.
cycle_until() {  # <home> <extended-regex> [absent]
  local h=$1 want=$2 absent=${3:-} n=0
  while [ "$n" -lt "${CYCLE_TRIES:-8}" ]; do
    n=$((n + 1))
    cycle "$h" "$absent"
    grep -qE "$want" "$h/events" && return 0
  done
  return 0
}

# Wait for one owned watcher cycle. Return its exit status when the watcher
# reports a wake. Otherwise stop it after <budget> hundred-millisecond polls, or
# after <limit> polls when a scan that was already running crossed that budget:
# that scan finishes and the cycle ends on its beacon, not inside it.
wait_for_scan() {  # <pid> <state> <mark> <budget> <limit>
  local pid=$1 state=$2 mark=$3 budget=${4:-40} limit=${5:-600} i=0
  while [ "$i" -lt "$limit" ]; do
    is_live_non_zombie "$pid" || break
    if [ "$i" -ge "$budget" ] && [ "$state/.last-watcher-beat" -nt "$mark" ]; then
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if is_live_non_zombie "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    i=0
    # A loaded runner takes a moment to run the watcher's own exit trap, and a
    # KILL there leaves the next cycle on a lock nothing released.
    while [ "$i" -lt 50 ] && is_live_non_zombie "$pid"; do
      sleep 0.1
      i=$((i + 1))
    done
    if is_live_non_zombie "$pid"; then
      printf 'wait_for_scan: owned pid %s survived TERM; sending KILL\n' "$pid" >&2
      kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    return 124
  fi
  wait "$pid"
}

# Make every terminal read in <home> cost <secs> of wall clock, the way a loaded

# Move every recorded time of an episode back by <secs>, as if it had waited.
backdate() {  # <home> <task> <secs>
  local f="$1/state/.waiting-timers/$2" sig since owner parent key misses card last v out=()
  IFS=$'\t' read -r sig since owner parent key misses card last < "$f"
  for v in "$since" "$owner" "$parent" "${card:-0}" "${last:-0}"; do
    if [ "$v" -gt 1 ]; then out+=("$((v - $3))"); else out+=("$v"); fi
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sig" "${out[0]}" "${out[1]}" "${out[2]}" "$key" "${misses:-0}" "${out[3]}" "${out[4]}" > "$f"
}

# What the owning lead appends to Main's state/<lead>.status when its worker's

# id:status line, one lane per window; every status is older than the wait thresholds.
test_a_planned_wait_raises_no_wake_and_an_open_blocker_still_does() {
  local m w n=0 future past
  m=$(home planned)
  future=$(date -u -d '+3 hours' +%Y-%m-%dT%H:%MZ)
  past=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%MZ)
  for w in "pa:paused [at=1]: change held for the release/c-6 branch until $future" \
    "bl:blocked [at=1] [key=held]: change held for the next release branch until $future" \
    "bo:blocked [at=1] [key=vendor]: waiting on the vendor" \
    "bp:blocked [at=1] [key=late]: change held for the next release branch until $past" \
    "sk:blocked [at=1] [key=release-c4-to-main]: waiting on the release branch"$'\n'"working [at=2] [key=release-c4-to-main]: the release branch landed, building" \
    "sp:blocked [at=1] [key=release-c4-to-main]: waiting on the release branch"$'\n'"paused [at=2] [key=release-c4-to-main]: held until the next window"; do
    n=$((n + 1))
    printf 'kind=ship\nbackend=tmux\nwindow=fake:%s\nharness=claude\n' "$n" > "$m/state/${w%%:*}.meta"
    printf '%s\n' "${w#*:}" > "$m/state/${w%%:*}.status"
    touch -d '-20 minutes' "$m/state/${w%%:*}.status"
    prime_status_seen "$m/state" "$m/state/${w%%:*}.status"
  done
  for n in 1 2 3 4 5; do
    PANES='1 2 3 4 5 6' cycle "$m"
    for w in pa bl bo bp sk sp; do [ ! -f "$m/state/.waiting-timers/$w" ] || backdate "$m" "$w" 700; done
  done
  printf "events: %s\n" "$(cat "$m/events")" >&2
  for w in pa:1 bl:2 sk:5 sp:6; do
    ! grep -q -E "(^|[^a-z])${w%:*}([^a-z]|$)|fake:${w#*:}" "$m/events" || fail "a planned wait on ${w%:*} raised a wake: $(cat "$m/events")"
  done
  grep -q -E "waiting-state bo .*level=owner" "$m/events" || fail "a blocked wait with no clearing condition did not escalate: $(cat "$m/events")"
  grep -q -E "waiting-state bp .*level=owner" "$m/events" || fail "a planned wait past its clearing time did not escalate: $(cat "$m/events")"
  pass "a newer working or paused line under the same key clears the older blocked wait; a planned wait is silent until its clearing time, and an open blocker escalates"
}

# The wait is already armed from a blocked line when a newer line under the same key arrives: the
# newest line is authoritative, so the armed timer drops and nothing escalates. A lane whose blocked
# line stays the newest still escalates.
test_a_newer_line_under_the_same_key_clears_an_armed_wait() {
  local m w n=0
  m=$(home newer)
  for w in "nw:working" "np:paused" "nb:blocked"; do
    n=$((n + 1))
    printf 'kind=ship\nbackend=tmux\nwindow=fake:%s\nharness=claude\n' "$n" > "$m/state/${w%%:*}.meta"
    printf 'blocked [at=1] [key=release-c4-to-main]: waiting on the release branch\n' > "$m/state/${w%%:*}.status"
    touch -d '-20 minutes' "$m/state/${w%%:*}.status"
    prime_status_seen "$m/state" "$m/state/${w%%:*}.status"
  done
  PANES='1 2 3' cycle "$m"
  for w in nw np nb; do [ ! -f "$m/state/.waiting-timers/$w" ] || backdate "$m" "$w" 300; done
  printf 'working [at=2] [key=release-c4-to-main]: the release branch landed, building\n' >> "$m/state/nw.status"
  printf 'paused [at=2] [key=release-c4-to-main]: held until the next window\n' >> "$m/state/np.status"
  for n in 1 2 3 4 5; do
    PANES='1 2 3' cycle "$m"
    for w in nw np nb; do [ ! -f "$m/state/.waiting-timers/$w" ] || backdate "$m" "$w" 700; done
  done
  printf "events: %s\n" "$(cat "$m/events")" >&2
  ! grep -q -E "waiting-state (nw|np) " "$m/events" || fail "a newer line under the same key did not clear the armed wait: $(cat "$m/events")"
  grep -q -E "waiting-state nb .*level=owner" "$m/events" || fail "a blocked line with no newer line did not escalate: $(cat "$m/events")"
  pass "a newer working or paused line under the same key drops the armed wait; an unchanged blocker still escalates"
}

test_a_planned_wait_raises_no_wake_and_an_open_blocker_still_does
test_a_newer_line_under_the_same_key_clears_an_armed_wait
