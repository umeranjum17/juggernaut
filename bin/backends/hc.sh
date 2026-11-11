#!/usr/bin/env bash
# bin/backends/hc.sh - the Herdr Core (hc) terminal session-provider adapter.
#
# Herdr Core runs programs in terminals that outlive their clients, addressed
# per machine (`t1`), with labels and no workspaces or panes. docs/hc-backend.md
# owns this backend's contract, its lab, and the slices still to land; this file
# holds the core primitives only. hc is a KNOWN backend, never a spawn-capable
# one, until its verify plan lands (bin/jg-backend.sh JG_BACKEND_SPAWN).
#
# Target string shape: "<hc session>:<terminal address>", e.g. "default:t3".
# The address is the one `hc run` returned for the terminal on this machine.
#
# Every hc client call auto-starts a core for its session when none listens
# (herdr-core 0.1.18 client.rs connect_or_start), so every read here first
# proves the session's core is listening and otherwise reports that nothing
# was proven. A stopped core is never evidence that a terminal is gone: its
# holders keep programs running across core restarts.

# Shared composer classifier and harness-process identity, as the other
# adapters use them, so no shape or process-name rule lives here.
# shellcheck source=bin/jg-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../jg-composer-lib.sh"
# shellcheck source=bin/jg-agent-process-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../jg-agent-process-lib.sh"

# The oldest Herdr Core release this adapter was proven against.
JG_BACKEND_HC_MIN_VERSION=0.1.18
JG_BACKEND_HC_DEFAULT_SIGNALS=()

jg_backend_hc_bin() {
  printf '%s' "${JG_BACKEND_HC_BIN:-hc}"
}

jg_backend_hc_version_at_least() {  # <version> <floor>
  awk -v have="$1" -v want="$2" 'BEGIN {
    split(have, a, /[.-]/); split(want, b, /[.-]/)
    for (i = 1; i <= 3; i++) { if (a[i] + 0 > b[i] + 0) exit 0; if (a[i] + 0 < b[i] + 0) exit 1 }
    exit 0
  }'
}

# jg_backend_hc_tool_check: hc and jq are present and hc meets the tested
# floor. `hc --version` starts no core. Checked once per process.
jg_backend_hc_tool_check() {
  local bin version
  [ -z "${_JG_BACKEND_HC_TOOLS_OK:-}" ] || return 0
  bin=$(jg_backend_hc_bin)
  command -v "$bin" >/dev/null 2>&1 || {
    echo "error: the hc backend needs Herdr Core: '$bin' is not on PATH" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || { echo "error: the hc backend needs jq" >&2; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "error: the hc backend needs python3" >&2; return 1; }
  version=$("$bin" --version 2>/dev/null)
  version=${version#hc }
  case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "error: cannot read the Herdr Core version from '$bin --version'" >&2; return 1 ;;
  esac
  jg_backend_hc_version_at_least "$version" "$JG_BACKEND_HC_MIN_VERSION" || {
    echo "error: Herdr Core $version is older than the tested $JG_BACKEND_HC_MIN_VERSION; run hc update" >&2
    return 1
  }
  _JG_BACKEND_HC_TOOLS_OK=1
}

# jg_backend_hc_socket_path: where the core of <session> listens, by Herdr
# Core's own rule (0.1.18 paths.rs and platform/unix.rs): HC_SOCKET, else
# <runtime dir>/herdr-core/<session>.sock, where the runtime dir is
# XDG_RUNTIME_DIR, else /run/user/<uid> when it exists, else the session's
# state directory. A `socket` set in the hc config file is not followed: the
# core then reads as not running, which proves nothing either way.
jg_backend_hc_socket_path() {  # <session>
  local session=$1 run
  if [ -n "${HC_SOCKET:-}" ]; then
    printf '%s' "$HC_SOCKET"
    return 0
  fi
  run=${XDG_RUNTIME_DIR:-}
  [ -n "$run" ] || { [ ! -d "/run/user/$(id -u)" ] || run="/run/user/$(id -u)"; }
  if [ -n "$run" ]; then
    printf '%s/herdr-core/%s.sock' "$run" "$session"
  else
    # No runtime dir: hc puts the socket in the session's state directory.
    printf '%s/herdr-core/%s/%s.sock' "${XDG_STATE_HOME:-$HOME/.local/state}" "$session" "$session"
  fi
}

# jg_backend_hc_core_listening: a core accepts connections for <session>.
# A plain connect, never an hc client call, so it can start nothing.
jg_backend_hc_core_listening() {  # <session>
  local socket
  socket=$(jg_backend_hc_socket_path "$1")
  [ -S "$socket" ] || return 1
  python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(2)
s.connect(sys.argv[1])' "$socket" 2>/dev/null
}

# jg_backend_hc_cli: one hc call against <session>, bounded by
# JG_BACKEND_HC_TIMEOUT seconds (default 20) where timeout(1) exists.
# JG_BACKEND_HC_DEFAULT_SIGNALS: the argv prefix that runs a command with every
# signal at its default action. A client call with no core starts one, and the
# core and every program it runs inherit the caller's ignored signals: started
# from a background job (SIGINT ignored), C-c could then never stop a task.
# GNU env resets them; elsewhere a python3 exec does (python3 ignores SIGPIPE
# and SIGXFSZ itself, so it resets every signal it can).
jg_backend_hc_default_signals() {
  if env --default-signal true >/dev/null 2>&1; then
    JG_BACKEND_HC_DEFAULT_SIGNALS=(env --default-signal)
  else
    JG_BACKEND_HC_DEFAULT_SIGNALS=(python3 -I -c 'import os, signal, sys
for s in signal.valid_signals():
    try: signal.signal(s, signal.SIG_DFL)
    except (OSError, ValueError): pass
os.execvp(sys.argv[1], sys.argv[1:])')
  fi
}

jg_backend_hc_cli() {  # <session> <hc arguments...>
  local session=$1 bin
  shift
  bin=$(jg_backend_hc_bin)
  [ "${#JG_BACKEND_HC_DEFAULT_SIGNALS[@]}" -gt 0 ] || jg_backend_hc_default_signals
  if command -v timeout >/dev/null 2>&1; then
    HC_SESSION="$session" timeout -k 1 "${JG_BACKEND_HC_TIMEOUT:-20}" "${JG_BACKEND_HC_DEFAULT_SIGNALS[@]}" "$bin" "$@"
  else
    HC_SESSION="$session" "${JG_BACKEND_HC_DEFAULT_SIGNALS[@]}" "$bin" "$@"
  fi
}

# jg_backend_hc_parse_target: split <target> into JG_BACKEND_HC_SESSION and
# JG_BACKEND_HC_TERMINAL. Only a local address (`t3`) is accepted.
jg_backend_hc_parse_target() {  # <target>
  JG_BACKEND_HC_SESSION=${1%%:*}
  JG_BACKEND_HC_TERMINAL=${1#*:}
  case "$JG_BACKEND_HC_SESSION" in
    ''|*[!A-Za-z0-9._-]*) echo "error: malformed hc target '$1' (want <session>:<terminal>)" >&2; return 1 ;;
  esac
  case "$JG_BACKEND_HC_TERMINAL" in
    t[0-9]*) ;;
    *) echo "error: malformed hc target '$1' (want <session>:<terminal>)" >&2; return 1 ;;
  esac
  case "$JG_BACKEND_HC_TERMINAL" in
    *[!a-z0-9]*) echo "error: malformed hc target '$1' (want <session>:<terminal>)" >&2; return 1 ;;
  esac
}

# jg_backend_hc_terminal_json: one `hc get` of <target>, printing its record.
# Returns 0 with the record, 3 when hc answers not_found, 4 when no core is
# listening for the session, and 1 for any other failure.
jg_backend_hc_terminal_json() {  # <target>
  local out err kind
  jg_backend_hc_parse_target "$1" || return 1
  jg_backend_hc_tool_check || return 1
  jg_backend_hc_core_listening "$JG_BACKEND_HC_SESSION" || return 4
  err=$(mktemp) || return 1
  out=$(jg_backend_hc_cli "$JG_BACKEND_HC_SESSION" get --json "$JG_BACKEND_HC_TERMINAL" 2>"$err")
  kind=$(jq -r '.error.kind // empty' "$err" 2>/dev/null)
  rm -f -- "$err"
  if [ "$(printf '%s' "$out" | jq -r '.address // empty' 2>/dev/null)" = "$JG_BACKEND_HC_TERMINAL" ]; then
    printf '%s' "$out"
    return 0
  fi
  [ "$kind" != not_found ] || return 3
  return 1
}

# jg_backend_hc_create_task: start <command...> in a new terminal of <session>
# in <cwd>, labelled jg.task=<task-id>, and print its target. --no-parent keeps
# the task alive when it is started from inside another hc terminal (by
# default a child ends with its parent's program).
jg_backend_hc_create_task() {  # <session> <task-id> <cwd> <command...>
  local session=$1 id=$2 cwd=$3 out address
  shift 3
  [ "$#" -gt 0 ] || { echo "error: hc create needs a command" >&2; return 1; }
  jg_backend_hc_tool_check || return 1
  out=$(jg_backend_hc_cli "$session" run --bg --json --no-parent --no-notify \
    --cwd "$cwd" --label "jg.task=$id" -- "$@") || {
    echo "error: hc run failed for task $id in session $session" >&2
    return 1
  }
  address=$(printf '%s' "$out" | jq -r '.address // empty' 2>/dev/null)
  case "$address" in
    t[0-9]*) printf '%s:%s' "$session" "$address" ;;
    *) echo "error: hc run returned no terminal address for task $id: $out" >&2; return 1 ;;
  esac
}

# jg_backend_hc_capture: the last <lines> lines of history plus screen.
jg_backend_hc_capture() {  # <target> <lines> [expected-label]
  local lines=${2:-40} out
  case "$lines" in ''|*[!0-9]*) lines=40 ;; esac
  jg_backend_hc_parse_target "$1" || return 1
  jg_backend_hc_tool_check || return 1
  jg_backend_hc_core_listening "$JG_BACKEND_HC_SESSION" || {
    echo "error: no Herdr Core is running for session $JG_BACKEND_HC_SESSION" >&2
    return 1
  }
  out=$(jg_backend_hc_cli "$JG_BACKEND_HC_SESSION" read --json --lines "$lines" "$JG_BACKEND_HC_TERMINAL") || return 1
  printf '%s' "$out" | jq -er '.text | strings' | tail -n "$lines"
}

# jg_backend_hc_visible_capture: the screen only. `hc read` without --lines
# returns the screen with no history above it.
jg_backend_hc_visible_capture() {  # <target> [expected-label]
  local out
  jg_backend_hc_parse_target "$1" || return 1
  jg_backend_hc_tool_check || return 1
  jg_backend_hc_core_listening "$JG_BACKEND_HC_SESSION" || {
    echo "error: no Herdr Core is running for session $JG_BACKEND_HC_SESSION" >&2
    return 1
  }
  out=$(jg_backend_hc_cli "$JG_BACKEND_HC_SESSION" read --json "$JG_BACKEND_HC_TERMINAL") || return 1
  printf '%s' "$out" | jq -er '.text | strings'
}

jg_backend_hc_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'esc' ;;
    C-c|c-c|ctrl+c|Ctrl+C) printf 'ctrl+c' ;;
    C-u|c-u|ctrl+u|Ctrl+U) printf 'ctrl+u' ;;
    BSpace|Backspace|backspace) printf 'backspace' ;;
    *) printf '%s' "$1" ;;
  esac
}

jg_backend_hc_send_key() {  # <target> <key> [expected-label]
  local key
  jg_backend_hc_parse_target "$1" || return 1
  jg_backend_hc_tool_check || return 1
  jg_backend_hc_core_listening "$JG_BACKEND_HC_SESSION" || {
    echo "error: no Herdr Core is running for session $JG_BACKEND_HC_SESSION" >&2
    return 1
  }
  key=$(jg_backend_hc_normalize_key "$2")
  jg_backend_hc_cli "$JG_BACKEND_HC_SESSION" keys --json "$JG_BACKEND_HC_TERMINAL" "$key" >/dev/null
}

# jg_backend_hc_composer_caps: static capability facts for the shared
# classifier. `hc read` returns plain text with escapes stripped.
jg_backend_hc_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$JG_COMPOSER_CAPTURE_LINES"
}

jg_backend_hc_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(jg_backend_hc_capture "$1" "$JG_COMPOSER_CAPTURE_LINES" 2>/dev/null) || { printf 'unknown'; return 0; }
  verdict=$(jg_composer_classify_screen "$(jg_backend_hc_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# jg_backend_hc_send_text_submit: deliver <text> with one `hc send`, which
# pastes it and presses Enter, and refuses a program that reports a blocking
# dialog. A composer still holding the text gets the shared retry-Enter loop
# (bin/jg-composer-lib.sh jg_composer_submit_retry_core), never a retype.
# Echoes `missing` for a terminal hc does not know, `dead` for a finished
# one, `send-failed` when the send was not accepted, else the composer verdict.
jg_backend_hc_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 json rc=0 state
  jg_backend_hc_parse_target "$target" || { printf 'send-failed'; return 0; }
  json=$(jg_backend_hc_terminal_json "$target") || rc=$?
  case "$rc" in
    0) ;;
    3) printf 'missing'; return 0 ;;
    *) printf 'send-failed'; return 0 ;;
  esac
  [ "$(printf '%s' "$json" | jq -r '.state')" = live ] || { printf 'dead'; return 0; }
  jg_backend_hc_cli "$JG_BACKEND_HC_SESSION" send --json "$JG_BACKEND_HC_TERMINAL" "$text" >/dev/null 2>&1 \
    || { printf 'send-failed'; return 0; }
  sleep "$settle"
  state=$(jg_backend_hc_composer_state "$target")
  case "$state" in
    pending|pending-unproven)
      if [ "$retries" -gt 1 ]; then
        jg_composer_submit_retry_core jg_backend_hc_send_key jg_backend_hc_composer_state \
          "$target" "$((retries - 1))" "$sleep_s"
        return 0
      fi
      ;;
  esac
  printf '%s' "$state"
}

# jg_backend_hc_kill: end the terminal's program (`hc kill`: hangup, then
# escalate), remove the finished terminal, and confirm hc no longer knows it.
# A target hc already answers not_found for is gone: 0. With no core listening
# nothing can be proven, because a holder may still run the program: 1.
jg_backend_hc_kill() {  # <target>
  local json rc=0 tries=0
  jg_backend_hc_parse_target "$1" || return 1
  json=$(jg_backend_hc_terminal_json "$1") || rc=$?
  case "$rc" in
    0) ;;
    3) return 0 ;;
    4) echo "error: no Herdr Core is running for session $JG_BACKEND_HC_SESSION; cannot prove $1 closed" >&2; return 1 ;;
    *) echo "error: cannot read hc terminal $1" >&2; return 1 ;;
  esac
  if [ "$(printf '%s' "$json" | jq -r '.state')" = live ]; then
    jg_backend_hc_cli "$JG_BACKEND_HC_SESSION" kill --json "$JG_BACKEND_HC_TERMINAL" >/dev/null 2>&1 || true
  fi
  while :; do
    jg_backend_hc_cli "$JG_BACKEND_HC_SESSION" rm --json "$JG_BACKEND_HC_TERMINAL" >/dev/null 2>&1 || true
    rc=0
    jg_backend_hc_terminal_json "$1" >/dev/null || rc=$?
    [ "$rc" -ne 3 ] || return 0
    [ "$tries" -lt 20 ] || break
    sleep 0.25
    tries=$((tries + 1))
  done
  echo "error: hc terminal $1 is still present after kill" >&2
  return 1
}

# jg_backend_hc_target_exists: the terminal is known and its program runs.
jg_backend_hc_target_exists() {  # <target> [expected-label]
  local json
  json=$(jg_backend_hc_terminal_json "$1" 2>/dev/null) || return 1
  [ "$(printf '%s' "$json" | jq -r '.state')" = live ]
}

# jg_backend_hc_target_absent: `absent` only on hc's own not_found answer from
# a listening core; `present` when hc returns the record (live or finished);
# `uncertain` otherwise.
jg_backend_hc_target_absent() {  # <target>
  local rc=0
  jg_backend_hc_terminal_json "$1" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) printf 'present' ;;
    3) printf 'absent' ;;
    *) printf 'uncertain' ;;
  esac
}

# jg_backend_hc_agent_state: the recovery-grade verdict of bin/jg-backend.sh
# jg_backend_agent_state. A finished terminal is `dead`; a live one is judged
# by its foreground process through the shared classifier: a harness is
# `alive`, a bare shell `dead`, anything else `ambiguous`.
jg_backend_hc_agent_state() {  # <target>
  local json rc=0 name argv0 args pid
  json=$(jg_backend_hc_terminal_json "$1" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    3) printf 'missing'; return 0 ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  case "$(printf '%s' "$json" | jq -r '.state')" in
    finished) printf 'dead'; return 0 ;;
    live) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  name=$(printf '%s' "$json" | jq -r '.foreground.name // empty')
  argv0=$(printf '%s' "$json" | jq -r '.foreground.argv[0] // empty')
  args=$(printf '%s' "$json" | jq -r '(.foreground.argv // []) | join(" ")')
  pid=$(printf '%s' "$json" | jq -r '.foreground.pid // empty')
  [ -n "$name" ] || { printf 'ambiguous'; return 0; }
  case "$(jg_agent_process_classify "$name" "$argv0" "$args" "$pid")" in
    agent) printf 'alive' ;;
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

jg_backend_hc_agent_exited() {  # <target>
  [ "$(jg_backend_hc_agent_state "$1")" = dead ]
}
