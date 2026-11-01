#!/usr/bin/env bash
# tests/wake-helpers.sh - shared fixtures and mocks for the wake-queue,
# watcher/lock, and supervise-daemon suites. The fake tmux surfaces here encode
# watcher/daemon/composer behavior, so they live here rather than in the generic
# tests/lib.sh. Generic reporters/assertions come from lib.sh, pulled in below.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# jg-wake-drain.sh now calls jg-guard.sh to assert watcher liveness on every
# drain. jg-guard.sh's first check warns when the juggernaut PRIMARY checkout
# (JG_ROOT) sits on a feature branch; with no override JG_ROOT resolves to the
# test runner's own checkout, which during validation is on a feature branch, so
# each drain would emit a spurious worktree-tangle banner. Point the tangle check
# at a fresh non-git dir to keep it inert across these suites - the same trick the
# direct jg-guard.sh tests use. A per-call JG_ROOT_OVERRIDE still wins where a
# suite sets its own (e.g. the watcher-lock guard-banner cases).
if [ -z "${JG_ROOT_OVERRIDE:-}" ]; then
  JG_ROOT_OVERRIDE="$(jg_test_tmproot jg-wake-tangle-root)"
  export JG_ROOT_OVERRIDE
fi

# Captain-channel quiet seam. The away-mode wedge alert reaches the captain by
# the one captain channel (bin/jg-bus.sh, docs/captain-channel.md), whose live
# mode posts to a bus and an iPad that no test has business reaching. Point every
# daemon and wake suite at a `mode off` channel config, so a sourced or spawned
# daemon records and delivers nothing: it is impossible to forget, because
# sourcing this harness installs it (an explicit JG_CAPTAIN_CHANNEL still wins).
if [ -z "${JG_CAPTAIN_CHANNEL:-}" ]; then
  _jg_channel_off=$(jg_test_tmproot jg-captain-channel-off)/off.conf
  printf 'set mode off\n' > "$_jg_channel_off"
  export JG_CAPTAIN_CHANNEL="$_jg_channel_off"
fi

# append_wake <state> <kind> <key> <payload>: append a wake record to the durable
# queue in a subshell scoped to <state>, using the production wake library.
append_wake() {
  local state=$1 kind=$2 key=$3 payload=$4 lib="$ROOT/bin/jg-wake-lib.sh"
  JG_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    jg_wake_append "$2" "$3" "$4"
  ' _ "$lib" "$kind" "$key" "$payload"
}

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  jg_test_track_watcher_state "$dir/state"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-windows" ]; then
  if [ -n "${JG_FAKE_TMUX_LIST_WINDOWS_FAIL:-}" ]; then
    printf 'fake tmux: inventory read failed\n' >&2
    exit 1
  fi
  if [ -n "${JG_FAKE_TMUX_WINDOWS:-}" ]; then
    printf '%s\n' "$JG_FAKE_TMUX_WINDOWS"
  elif [ -n "${JG_FAKE_TMUX_WINDOW:-}" ]; then
    printf '%s\n' "${JG_FAKE_TMUX_WINDOW#*:}"
  fi
  exit 0
fi
if [ "${1:-}" = "capture-pane" ]; then
  if [ -n "${JG_FAKE_TMUX_CAPTURE_COUNT_FILE:-}" ]; then
    _capture_count=$(cat "$JG_FAKE_TMUX_CAPTURE_COUNT_FILE" 2>/dev/null || echo 0)
    printf '%s\n' "$((_capture_count + 1))" > "$JG_FAKE_TMUX_CAPTURE_COUNT_FILE"
    if [ -n "${JG_FAKE_TMUX_CAPTURE_FAIL_AFTER:-}" ] \
      && [ "$_capture_count" -ge "$JG_FAKE_TMUX_CAPTURE_FAIL_AFTER" ]; then
      exit 1
    fi
  fi
  if [ -n "${JG_FAKE_TMUX_FORBIDDEN_TARGET:-}" ]; then
    _prev=
    for _arg in "$@"; do
      if [ "$_prev" = -t ] && [ "$_arg" = "$JG_FAKE_TMUX_FORBIDDEN_TARGET" ]; then
        exit 1
      fi
      _prev=$_arg
    done
  fi
  if [ -n "${JG_FAKE_TMUX_CAPTURE:-}" ]; then
    cat "$JG_FAKE_TMUX_CAPTURE"
  fi
  exit 0
fi
if [ "${1:-}" = "display-message" ]; then
  case "$*" in
    *pane_current_command*) printf '%s\n' "${JG_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;;
  esac
fi
exit 1
SH
  chmod +x "$fakebin/tmux"
  make_fake_crew_state "$fakebin" >/dev/null
  printf '%s\n' "$dir"
}

# Install a hermetic fake jg-crew-state.sh into <fakebin> and echo its path. The
# watcher's absorb-only-when-provably-working triage calls this (via
# JG_CREW_STATE_BIN) to read a crew's current state on no-verb signal and stale
# paths; the fake returns a canned "state: <s> · source: <src> · <detail>"
# verdict line so a test can fix the provably-working decision without a real
# worktree or no-mistakes.
# A per-id override JG_FAKE_CREW_STATE_<sanitized-id> wins; otherwise the shared
# JG_FAKE_CREW_STATE; otherwise an unknown verdict (NOT provably working), the
# safe default so a test that forgets to set one surfaces rather than absorbs.
# Exporting JG_FAKE_CREW_STATE_LOG appends one line per call, so a test that
# asserts how many current-state reads a path spends - the reads are the costly
# half of watcher triage - can count them instead of inferring them.
make_fake_crew_state() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/jg-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
[ -z "${JG_FAKE_CREW_STATE_LOG:-}" ] || printf '%s\n' "$id" >> "$JG_FAKE_CREW_STATE_LOG"
key=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '_')
var="JG_FAKE_CREW_STATE_$key"
val=${!var:-${JG_FAKE_CREW_STATE:-}}
printf '%s\n' "${val:-state: unknown · source: none · fake default}"
exit 0
SH
  chmod +x "$fakebin/jg-crew-state.sh"
  printf '%s\n' "$fakebin/jg-crew-state.sh"
}

# Prime <file>'s .seen-* marker to its CURRENT signature through the production
# signature owner (bin/jg-wake-lib.sh), so a test can declare "everything in
# this file was already surfaced or deliberately absorbed" before exercising
# the next wake, self-announced append, or annotation decision.
prime_status_seen() {  # <state> <file>
  JG_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    jg_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/jg-wake-lib.sh" "$1" "$2"
}

# Print the generation from a recovery marker token of any status/kind.
recovery_marker_generation() {  # <marker-file>
  sed -n 's/^[^:]*:[^:]*:\(.*\)$/\1/p' "$1"
}

# Acknowledge a drain from its captured stderr (the WAKE_ACK_REQUIRED line).
ack_drain_err() {  # <state> <stderr-file>
  local state=$1 err=$2 sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  JG_STATE_OVERRIDE="$state" "$ROOT/bin/jg-wake-drain.sh" \
    --ack-through "$sequence" --recovery-generation "$generation"
}

make_supercase() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  jg_test_track_watcher_state "$dir/state"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${JG_FAKE_TMUX_PANE_ALIVE:-1}" = "1" ] || exit 1
    _print=0
    # Return cursor_y when the format asks for it (pane_input_pending).
    for _a in "$@"; do
      case "$_a" in *cursor_y*) printf '%s\n' "${JG_FAKE_TMUX_CURSOR_Y:-0}"; exit 0 ;; esac
      [ "$_a" = "-p" ] && _print=1
    done
    [ "$_print" = 1 ] && printf 'fakepane\n'
    exit 0 ;;
  list-windows)
    [ -n "${JG_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$JG_FAKE_TMUX_WINDOW"
    exit 0 ;;
  capture-pane)
    # Honor a single-line band capture (-S N -E M, both non-negative) for the
    # composer reader's non-bordered compatibility fallback; otherwise (e.g. its
    # structural full-pane scan or jg_pane_is_busy's "-S -40" tail) return the whole capture. -e is accepted and
    # ignored: this fake emits plain text, which the dim-stripper passes through.
    _S=""; _E=""; shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -S) _S="${2:-}"; shift 2; continue ;;
        -E) _E="${2:-}"; shift 2; continue ;;
        *) shift ;;
      esac
    done
    [ -n "${JG_FAKE_TMUX_CAPTURE:-}" ] || exit 0
    if [ -n "$_S" ] && [ -n "$_E" ]; then
      case "$_S$_E" in
        *[!0-9]*) cat "$JG_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
        *) sed -n "$((_S + 1)),$((_E + 1))p" "$JG_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
      esac
    else
      cat "$JG_FAKE_TMUX_CAPTURE" 2>/dev/null
    fi
    exit 0 ;;
  send-keys)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -l) shift; [ "$#" -gt 0 ] && {
          printf '%s\n' "$1" >> "${JG_FAKE_TMUX_SENT:-/dev/null}"
          # Reflect sent text into capture so pane_input_pending sees it as
          # pending input (text in the composer).
          [ -n "${JG_FAKE_TMUX_CAPTURE:-}" ] && printf '%s\n' "$1" >> "$JG_FAKE_TMUX_CAPTURE"
        } ;;
        Enter)
          # Optionally swallow Enter (file-based flag) to test the retry path.
          if [ -n "${JG_FAKE_TMUX_SWALLOW_FILE:-}" ] && [ -f "$JG_FAKE_TMUX_SWALLOW_FILE" ]; then
            rm -f "$JG_FAKE_TMUX_SWALLOW_FILE"
          else
            printf '[ENTER]\n' >> "${JG_FAKE_TMUX_SENT:-/dev/null}"
            # Enter submits: clear the last line (the typed text) from the
            # capture, simulating the composer being cleared on submit.
            if [ -n "${JG_FAKE_TMUX_CAPTURE:-}" ] && [ -s "$JG_FAKE_TMUX_CAPTURE" ]; then
              _tmp=$(mktemp 2>/dev/null) || _tmp="${JG_FAKE_TMUX_CAPTURE}.tmp"
              sed '$d' "$JG_FAKE_TMUX_CAPTURE" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$JG_FAKE_TMUX_CAPTURE"
              rm -f "$_tmp" 2>/dev/null
            fi
          fi
          ;;
      esac
      shift
    done
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

make_bordered_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  jg_test_track_watcher_state "$dir/state"
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$dir/composer"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${JG_FAKE_COMPOSER:?JG_FAKE_COMPOSER unset}"
write_composer() {
  text=$1
  width=$((${#text} + 4))
  border=
  i=0
  while [ "$i" -lt "$width" ]; do
    border="${border}─"
    i=$((i + 1))
  done
  printf '╭%s╮\n│ > %s │\n╰%s╯\n' "$border" "$text" "$border" > "$COMPOSER"
}
case "${1:-}" in
  display-message)
    print=0
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    for a in "$@"; do [ "$a" = "-p" ] && print=1; done
    [ "$print" = 1 ] && printf 'fakepane\n'
    exit 0 ;;
  capture-pane) cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    shift
    text=""; is_enter=0; lit=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l) lit=1 ;;
        Enter) is_enter=1 ;;
        *) [ "$lit" = 1 ] && text="$1" ;;
      esac
      shift
    done
    if [ "$is_enter" = 1 ]; then
      if [ -n "${JG_FAKE_SWALLOW:-}" ] && [ -f "$JG_FAKE_SWALLOW" ]; then
        [ "${JG_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$JG_FAKE_SWALLOW"
      else
        [ -n "${JG_FAKE_SENT:-}" ] && printf '[ENTER]\n' >> "$JG_FAKE_SENT"
        write_composer ""
      fi
    elif [ "$lit" = 1 ]; then
      [ "${JG_FAKE_SEND_FAIL:-0}" = 1 ] && exit 1
      # JG_FAKE_SEND_MAX_BYTES models a transport ceiling on one literal send.
      if [ -n "${JG_FAKE_SEND_MAX_BYTES:-}" ] \
        && [ "$(printf '%s' "$text" | LC_ALL=C wc -c | tr -d ' ')" -gt "$JG_FAKE_SEND_MAX_BYTES" ]; then
        echo "command too long" >&2
        exit 1
      fi
      [ -n "${JG_FAKE_SENT:-}" ] && printf '%s\n' "$text" >> "$JG_FAKE_SENT"
      write_composer "$text"
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

# Only pass a process owned by this test. A deadline must also bound cleanup:
# TERM can be ignored or remain pending on a stopped child, so never follow it
# with an unbounded wait. Keep process evidence before the final owned-PID kill.
wait_for_exit() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! is_live_non_zombie "$pid"; then
      wait "$pid"
      return "$?"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  printf 'wait_for_exit: owned pid %s exceeded %s polls; sending TERM\n' "$pid" "$limit" >&2
  ps -p "$pid" -o pid= -o ppid= -o stat= -o command= >&2 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 20 ] && is_live_non_zombie "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  if is_live_non_zombie "$pid"; then
    printf 'wait_for_exit: owned pid %s survived TERM; sending KILL\n' "$pid" >&2
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  return 124
}

is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

hash_text() {
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

dead_pid() {
  local p=999999
  while kill -0 "$p" 2>/dev/null; do
    p=$((p + 1))
  done
  printf '%s\n' "$p"
}
