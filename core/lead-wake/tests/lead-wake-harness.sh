#!/usr/bin/env bash
# Harness functions the lead-wake journey needs, carried verbatim from the fork suites
# (watch-triage and wake-queue) so the journey no longer reads those suites at run time.
# Sourced by jg-lead-wake.test.sh after tests/wake-helpers.sh; it defines functions only.
ack_stopped_cycle() {  # <state>
  local state=$1 out err rc=0 sequence generation attempt
  out="$state/.test-cycle-drain.out"
  err="$state/.test-cycle-drain.err"
  for attempt in 1 2 3 4 5; do
    rc=0
    JG_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || rc=$?
    sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
    generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
    [ "$rc" -eq 0 ] && [ -n "$sequence" ] && [ -n "$generation" ] && break
    {
      printf 'ack_stopped_cycle: attempt %s missed: drain exit=%s, no usable WAKE_ACK_REQUIRED\n' "$attempt" "$rc"
      printf -- '--- drain stdout\n'; cat "$out"
      printf -- '--- drain stderr\n'; cat "$err"
      printf -- '--- downtime marker: %s\n' "$(cat "$state/.watcher-down" 2>/dev/null || echo absent)"
    } >&2
    [ "$attempt" -eq 5 ] || sleep 0.2
  done
  rm -f "$out" "$err"
  if [ "$rc" -ne 0 ] || [ -z "$sequence" ] || [ -z "$generation" ]; then
    return 1
  fi
  JG_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" JG_STATE_OVERRIDE="$state" JG_CREW_STATE_BIN="$fakebin/jg-crew-state.sh" \
    XDG_DATA_HOME="$state/.xdg-data" \
    JG_POLL=1 JG_SIGNAL_GRACE=1 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 \
    JG_SQUAD_LEAD_LIVENESS_SECS=99999999 "$@" "$WATCH" > "$out" &
}

wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

reap() {
  local rc
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100
  rc=$?
  [ "$rc" -ne 124 ] || fail "watcher pid $1 did not exit within 10s of TERM"
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

squad_lead_stall_watch_leg() { # <dir> <leg> <mode> [arg...]
  local dir=$1 leg=$2 mode=$3
  shift 3
  local out="$dir/watch-$leg.out" err="$dir/watch-$leg.err"
  local beat="$dir/state/.last-watcher-beat" sent="$dir/sent"
  local pid i=0 limit=600 met=0
  local marker='' want='' progress='' progress_start='' row_key='' bound=0
  local body key observed_at=0 first=0 mark=0 mtime
  case "$mode" in
    alert|reject|tick)
      ;;
    cleared)
      marker="$dir/state/.squad-lead-wake-progress-mate"
      printf 'unobserved\n' > "$marker"
      ;;
    progress)
      marker="$dir/state/.squad-lead-wake-progress-$1"
      want=$2
      ;;
    defer)
      marker="$dir/state/.squad-lead-wake-progress-$1"
      row_key=$2
      bound=${JG_SQUAD_LEAD_WAKE_STALL_SECS:-1}
      [ "${3:-0}" -le "$bound" ] || bound=$3
      ;;
    ring)
      marker="$dir/state/.squad-lead-wake-ring-$1"
      want=$2
      progress="$dir/state/.squad-lead-wake-progress-$1"
      ;;
    stall-file)
      marker="$dir/state/.squad-lead-wake-stall-$1"
      want=$2
      ;;
    drained)
      marker=$2
      progress="$dir/state/.squad-lead-wake-progress-$1"
      ;;
    *)
      fail "unknown stall watch mode: $mode"
      ;;
  esac
  [ -z "$progress" ] || progress_start=$(cat "$progress" 2>/dev/null || true)
  rm -f "$beat"
  # These legs pin wake-loop stall behavior only. A large cadence alone does
  # not suppress the first endpoint tick when its marker is absent; seed it so
  # every watcher launch and restart leaves the fixture endpoints untouched.
  touch "$dir/state/.squad-lead-liveness-tick"
  JG_SQUAD_LEAD_LIVENESS_SECS=99999999 "$WATCH" >"$out" 2>"$err" &
  pid=$!
  case "$mode" in
    alert)
      while [ "$i" -lt "$limit" ]; do
        if ! is_live_non_zombie "$pid"; then
          wait_for_exit "$pid" 50 || true
          if grep -F 'squad_lead wake-loop stalled' "$out" >/dev/null 2>&1; then
            return 0
          fi
          JG_SQUAD_LEAD_LIVENESS_SECS=99999999 "$WATCH" >>"$out" 2>>"$err" &
          pid=$!
        fi
        sleep 0.1
        i=$((i + 1))
      done
      wait_for_exit "$pid" 50 || true
      grep -F 'squad_lead wake-loop stalled' "$out" >/dev/null \
        || fail "watcher leg $leg did not alert: $(cat "$out" 2>/dev/null) $(cat "$err" 2>/dev/null)"
      return 0
      ;;
    reject)
      wait_for_exit "$pid" "$limit" || true
      grep -F 'watcher: squad_lead wake-loop observation failed' "$err" >/dev/null \
        || fail "watcher leg $leg did not refuse the stall marker path: $(cat "$out" 2>/dev/null) $(cat "$err" 2>/dev/null)"
      return 0
      ;;
  esac
  while [ "$i" -lt "$limit" ]; do
    met=0
    case "$mode" in
      tick)
        if [ -e "$beat" ]; then
          mtime=$(stall_watch_beat_epoch "$beat")
          if [ "$first" -eq 0 ]; then
            first=$mtime
          elif [ "$mtime" -gt "$first" ]; then
            met=1
          fi
        fi
        if [ "$met" -eq 0 ] && ! is_live_non_zombie "$pid" && stall_watch_has_wake "$out"; then
          met=1
        fi
        ;;
      cleared)
        [ ! -e "$marker" ] && met=1
        ;;
      defer)
        if [ "$observed_at" -eq 0 ]; then
          body=$(cat "$marker" 2>/dev/null || true)
          key=${body#*$'\t'}
          if [ -n "$key" ] && [ "$key" != "$body" ] && [ "$key" = "$row_key" ]; then
            observed_at=${body%%$'\t'*}
            case "$observed_at" in
              ''|*[!0-9]*) observed_at=0 ;;
            esac
          fi
        elif [ -e "$beat" ]; then
          mtime=$(stall_watch_beat_epoch "$beat")
          if [ "$mtime" -ge $((observed_at + bound)) ]; then
            if ! is_live_non_zombie "$pid" && stall_watch_has_wake "$out"; then
              met=1
            elif [ "$mark" -gt 0 ] && [ "$mtime" -gt "$mark" ]; then
              met=1
            else
              mark=$mtime
            fi
          fi
        fi
        if grep -F 'squad_lead wake-loop stalled' "$out" >/dev/null 2>&1; then
          fail "watcher leg $leg alerted during a deferred busy turn: $(cat "$out")"
        fi
        ;;
      *)
        stall_watch_record_met "$mode" "$marker" "$want" "$progress" "$progress_start" "$sent" && met=1
        ;;
    esac
    if [ "$met" -eq 1 ]; then
      break
    fi
    if ! is_live_non_zombie "$pid"; then
      # The process has flushed. A wake after the stall tick counts; a startup
      # exit does not, so start another watcher against the same fixture.
      wait_for_exit "$pid" 50 || true
      case "$mode" in
        tick)
          stall_watch_has_wake "$out" && met=1
          ;;
        cleared)
          [ ! -e "$marker" ] && met=1
          ;;
        defer)
          if [ "$observed_at" -gt 0 ] && stall_watch_has_wake "$out" \
            && ! grep -F 'squad_lead wake-loop stalled' "$out" >/dev/null 2>&1; then
            mtime=$(stall_watch_beat_epoch "$beat")
            [ "$mtime" -ge $((observed_at + bound)) ] && met=1
          fi
          ;;
        *)
          stall_watch_record_met "$mode" "$marker" "$want" "$progress" "$progress_start" "$sent" && met=1
          ;;
      esac
      if [ "$met" -eq 1 ]; then
        break
      fi
      rm -f "$beat"
      JG_SQUAD_LEAD_LIVENESS_SECS=99999999 "$WATCH" >>"$out" 2>>"$err" &
      pid=$!
      first=0
      mark=0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  [ "$met" -eq 1 ] \
    || fail "watcher leg $leg ($mode) did not observe the stall condition: $(cat "$out" 2>/dev/null) $(cat "$err" 2>/dev/null)"
  if is_live_non_zombie "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
  wait_for_exit "$pid" "$limit" || true
}

stall_watch_beat_epoch() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null || echo 0
  else
    stat -c %Y "$1" 2>/dev/null || echo 0
  fi
}

stall_watch_has_wake() { # <out>
  grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$1" >/dev/null 2>&1
}

stall_watch_record_met() { # <mode> <marker> <want> <progress> <progress-start> <sent>
  local mode=$1 marker=$2 want=$3 progress=$4 start=$5 sent=$6
  case "$mode" in
    progress)
      [ "$(cat "$marker" 2>/dev/null || true)" = "$want" ]
      ;;
    ring)
      [ "$(cat "$marker" 2>/dev/null || true)" = "$want" ] \
        && [ "$(cat "$progress" 2>/dev/null || true)" != "$start" ]
      ;;
    stall-file)
      [ -f "$marker" ] && [ ! -L "$marker" ] \
        && [ "$(cat "$marker" 2>/dev/null || true)" = "$want" ]
      ;;
    drained)
      [ ! -s "$marker" ] && [ -s "$sent" ] && grep -F '[ENTER]' "$sent" >/dev/null 2>&1 \
        && [ "$(cat "$progress" 2>/dev/null || true)" != "$start" ]
      ;;
    *)
      return 1
      ;;
  esac
}

install_squad_lead_alive_tmux() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) printf '%s\n' 'jg-mate' ;;
  capture-pane) exit 0 ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'claude\n' ;;
      *pane_tty*) exit 1 ;;
      *cursor_y*) printf '0\n' ;;
      *) printf '0\n' ;;
    esac
    ;;
  send-keys)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -l) shift; [ "$#" -gt 0 ] && printf '%s\n' "$1" >> "${JG_FAKE_TMUX_SENT:-/dev/null}" ;;
        Enter)
          printf '[ENTER]\n' >> "${JG_FAKE_TMUX_SENT:-/dev/null}"
          if [ -n "${JG_FAKE_CHILD_WAKE_QUEUE:-}" ]; then
            : > "$JG_FAKE_CHILD_WAKE_QUEUE"
          fi
          ;;
      esac
      shift
    done
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
}

install_squad_lead_stall_date() {  # <fakebin>
  local fakebin=$1 real_date
  real_date=$(command -v date)
  cat > "$fakebin/date" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = +%s ]; then
  cat "\${JG_FAKE_NOW_FILE:?}"
else
  exec "$real_date" "\$@"
fi
SH
  chmod +x "$fakebin/date"
}

