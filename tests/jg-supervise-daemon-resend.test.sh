#!/usr/bin/env bash
# tests/jg-supervise-daemon-resend.test.sh - private-socket end-to-end test for a
# swallowed submit at the afk daemon's injection path (fric-composer-resend).
#
# The pane swallows every Enter of the daemon's first injection, so the digest's
# own text stays in the composer. Today every later injection then defers for
# ever ("supervisor composer not confirmed-empty"). Pass: the daemon recognises
# its own text (the U+2063 marker) in the composer, submits it once without
# retyping, and the second item follows as its own line. Human text, which has
# no marker, is never submitted by the daemon (jg-afk-inject-e2e.test.sh A).
#
# Isolation: a private tmux socket and a throwaway state dir, as in
# jg-afk-inject-e2e.test.sh; nothing touches the live fleet.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/jg-supervise-daemon.sh"

# Skip gracefully if tmux is not installed.
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="afk-e2e-$$"
STATE_DIR=
TMUX_SHIM_DIR=
LOG_FILE=
DAEMON_PID=
SUPERVISOR_PANE=
LOOP_SCRIPT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  local file
  for file in "$LOG_FILE" "$STATE_DIR/daemon.out" "$STATE_DIR/daemon.err" "$STATE_DIR/transport.log"; do
    [ -f "$file" ] || continue
    printf '\n%s:\n' "${file##*/}" >&2
    cat "$file" >&2
  done
  cleanup_all
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    afk_exit "${STATE_DIR:-}" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [ -n "${SOCKET:-}" ] && [ -n "${REAL_TMUX:-}" ]; then
    "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fi
  rm -rf "${TMUX_SHIM_DIR:-}" 2>/dev/null || true
  rm -rf "${STATE_DIR:-}" 2>/dev/null || true
}
trap cleanup_all EXIT

# --- setup ------------------------------------------------------------------

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/jg-afk-e2e.XXXXXX")
export JG_HOME="$STATE_DIR/home" JG_ROOT_OVERRIDE="$ROOT"
export XDG_CONFIG_HOME="$JG_HOME/config" XDG_CACHE_HOME="$JG_HOME/cache" XDG_STATE_HOME="$JG_HOME/state"
export XDG_RUNTIME_DIR="$JG_HOME/run"
export JG_KV_URL=nats://127.0.0.1:1 JG_WAKE_BUS_URL=nats://127.0.0.1:1 JG_STATE_BUS_URL=nats://127.0.0.1:1
# A fixture is not the machine-service owner; host service findings are not test events.
mkdir -p "$JG_HOME/config" "$JG_HOME/data" "$JG_HOME/state"
mkdir -m 700 "$XDG_RUNTIME_DIR"
LOG_FILE="$STATE_DIR/submitted.log"
: > "$LOG_FILE"

# Source the daemon to get JG_INJECT_MARK, afk_enter, afk_exit.
# shellcheck source=/dev/null
. "$DAEMON"

# Private tmux server with a supervisor session.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 200 -y 50
SUPERVISOR_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t supervisor '#{pane_id}')

# Supervisor pane loop: a small deterministic composer that logs each submitted
# line verbatim (hex + text + classification). It draws the in-progress input
# itself instead of relying on the terminal driver's canonical-mode echo, because
# tmux cursor placement for that echo varies across CI environments.
LOOP_SCRIPT="$STATE_DIR/supervisor-loop.sh"
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\xE2\x81\xA3'
LOG="$1"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() {
  [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

_buf=
# The drawn composer row carries a real agent prompt glyph, matching the
# production supervisor pane this daemon injects into: under the strict
# container-proof rule (captain decision blank-row-injection-posture) a bare
# unidentified row is never a safe injection target, so the fixture must
# render the shape the classifier positively proves - "❯ " when idle,
# "❯ <buffer>" while input is pending. The glyph is rendering only; it never
# enters the buffer, so submitted-content assertions are unchanged.
redraw() {
  printf '\r\033[K\xe2\x9d\xaf %s' "$_buf"
}
submit_line() {
  local _line=$_buf _c _hex
  if [ "${_line:0:1}" = "$MARK" ]; then
    _c="injection"
  else
    _c="user"
  fi
  _hex=$(printf '%s' "$_line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$_hex" "$_line" "$_c" >> "$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
}

redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then
    submit_line
    continue
  fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"

# Start the loop in the supervisor pane.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" \
  "bash '$LOOP_SCRIPT' '$LOG_FILE'" Enter
sleep 1  # let the loop start and settle

# tmux shim: redirects bare `tmux` to the private socket. Optionally swallows
# the first Enter (file-based flag) for Scenario B.
TMUX_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/jg-shim.XXXXXX")
cat > "$TMUX_SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = send-keys ]; then
  printf '%q ' "\$@" >> "$STATE_DIR/transport.log"
  printf '\n' >> "$STATE_DIR/transport.log"
fi
if [ "\${1:-}" = "send-keys" ] && [ -f "$STATE_DIR/.swallow-enter" ]; then
  shift
  _args=()
  for _arg in "\$@"; do
    if [ "\$_arg" = "Enter" ] && [ -f "$STATE_DIR/.swallow-enter" ]; then
      _left=\$(cat "$STATE_DIR/.swallow-enter")
      if [ "\$_left" -le 1 ]; then rm -f "$STATE_DIR/.swallow-enter"; else echo \$((_left - 1)) > "$STATE_DIR/.swallow-enter"; fi
      continue
    fi
    _args+=("\$_arg")
  done
  exec "$REAL_TMUX" -L "$SOCKET" send-keys "\${_args[@]}"
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$TMUX_SHIM_DIR/tmux"

# Create a fake operator window (the watcher lists jg-* windows for stale
# detection). The pane is an inert shell - it just needs to exist.
"$REAL_TMUX" -L "$SOCKET" new-window -d -n jg-fake-c1 -t supervisor; "$REAL_TMUX" -L "$SOCKET" new-window -d -n jg-fake-c2 -t supervisor

# The fixture pane is no real harness, so each scenario pins the primary harness
# the daemon would otherwise detect from this test's own process ancestry:
# "unknown" preserves the typed U+2063 envelope, "claude" selects the
# record-backed doorbell that a marker-stripping Claude Code primary receives.
start_daemon() {  # [primary-harness]
  JG_DAEMON_PRIMARY_HARNESS="${1:-unknown}" \
  PATH="$TMUX_SHIM_DIR:$PATH" \
  JG_STATE_OVERRIDE="$STATE_DIR" \
  JG_SUPERVISOR_TARGET="$SUPERVISOR_PANE" \
  JG_SUPERVISOR_BACKEND=tmux \
  JG_ESCALATE_BATCH_SECS=0 \
  JG_HOUSEKEEPING_TICK=1 \
  JG_POLL=1 \
  JG_SIGNAL_GRACE=1 \
  JG_HEARTBEAT=999999 \
  JG_CHECK_INTERVAL=999999 \
  JG_INJECT_CONFIRM_SLEEP=0.3 \
  JG_INJECT_CONFIRM_RETRIES=5 \
  JG_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  # Wait for the daemon to start and acquire the lock.
  local i=0
  while [ "$i" -lt 30 ]; do
    [ -f "$STATE_DIR/.supervise-daemon.pid" ] && break
    sleep 0.2
    i=$((i + 1))
  done
  [ -f "$STATE_DIR/.supervise-daemon.pid" ] || {
    echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
    fail "daemon did not start (no pid file after 6s)"
  }
}

stop_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  afk_exit "$STATE_DIR" 2>/dev/null || true
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  sleep 1
}

reset_state() {
  # Clear daemon and watcher state for a fresh scenario.
  rm -f "$STATE_DIR"/*.status \
         "$STATE_DIR"/.subsuper-* \
         "$STATE_DIR"/.wake-queue* \
         "$STATE_DIR"/.watch.lock* \
         "$STATE_DIR"/.watcher-down* \
         "$STATE_DIR"/.last-* \
         "$STATE_DIR"/.hash-* \
         "$STATE_DIR"/.count-* \
         "$STATE_DIR"/.stale-* \
         "$STATE_DIR"/.seen-* \
         "$STATE_DIR"/.heartbeat-streak \
         "$STATE_DIR"/.swallow-enter \
         2>/dev/null || true
  : > "$LOG_FILE"
  : > "$STATE_DIR/transport.log"
}


# The pane drops every Enter of the first injection attempt (5 retries).
test_resend() {
  reset_state
  afk_enter "$STATE_DIR"
  echo 5 > "$STATE_DIR/.swallow-enter"
  start_daemon

  echo "done: PR https://example.test/pr/first" > "$STATE_DIR/fake-c1.status"
  sleep 8
  echo "done: PR https://example.test/pr/second" > "$STATE_DIR/fake-c2.status"
  sleep 8

  local n
  n=$(grep -c 'pr/first' "$LOG_FILE" || true)
  [ "$n" -eq 1 ] || fail "the swallowed digest was submitted $n times, expected exactly 1"
  n=$(grep -c 'pr/second' "$LOG_FILE" || true)
  [ "$n" -eq 1 ] || fail "the second digest was submitted $n times, expected exactly 1"
  n=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$n" -eq 2 ] || fail "expected 2 U+2063 markers (one per digest, no concatenation), got $n"
  grep -q $'\tuser$' "$LOG_FILE" && fail "a line was submitted as user text"

  stop_daemon
  pass "a swallowed digest is submitted once on the next try and the second digest follows"
}

test_resend
