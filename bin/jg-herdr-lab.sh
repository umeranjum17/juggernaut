#!/usr/bin/env bash
# Provision and operate an isolated Herdr lab session without risking the live
# default session.
#
# Usage:
#   jg-herdr-lab.sh name <label>
#   jg-herdr-lab.sh prepare <session>
#   jg-herdr-lab.sh provision <session>
#   jg-herdr-lab.sh run <session> <herdr arguments...>
#   jg-herdr-lab.sh viewer start <session>
#   jg-herdr-lab.sh viewer stop <session>
#   jg-herdr-lab.sh stop <session>
#   jg-herdr-lab.sh teardown <session>
#
# Named runtime calls always use disposable HOME and XDG_CONFIG_HOME,
# XDG_DATA_HOME, XDG_STATE_HOME, and XDG_CACHE_HOME in a short private /tmp/fhl.*
# directory recorded by <session>.xdg-root in the lab state directory.
# Teardown removes both the directory and pointer without copying credentials.
# Runtime clears exported CLAUDE_*, ANTHROPIC_*, OPENAI_API_KEY,
# PI_CODING_AGENT_DIR, and CODEX_HOME, then sets CLAUDE_CONFIG_DIR,
# PI_CODING_AGENT_DIR, and CODEX_HOME to home/.claude, home/.pi/agent,
# and home/.codex under that root.
# State and disposable directories must be owned, non-symlink, and mode 700;
# the owned, non-symlink .xdg-root pointer must name /tmp/fhl.<six alphanumerics>
# with a non-symlink .lab-session file matching the session name.
# Legacy <session>.xdg roots are refused pending guarded cleanup and fresh provisioning.
# docs/herdr-backend.md#destructive-lab-safety owns the isolation boundary.
# --isolated-xdg and JG_HERDR_LAB_ISOLATED_XDG=1 remain accepted for compatibility.
# The fleet-state tripwire reads with the caller's HOME and XDG environment.
# JG_HERDR_LAB_FLEET_HOME selects only the existing absolute fleet home for
# read-only fleet queries using its default XDG paths.
# Session names must begin with "jg-lab-" and can never be "default".
# The name command sanitizes the label, caps it at 16 characters, and appends
# process/random suffixes to keep generated socket paths short.
# Every Herdr call made here carries --session <session>: trailing, or
# immediately before the first -- delimiter so it stays a Herdr option instead
# of becoming a passthrough argument such as an agent start argument.
# The run command rejects caller-supplied --session flags, any leading option
# before the subcommand, all session lifecycle operations, and every server
# operation.
# Session stop is available only through guarded stop or teardown, and session
# delete is available only through teardown.
# Both paths perform a fresh refuse-default check immediately before each
# destructive call.
# Provision records the running default session as a fleet-state tripwire and
# teardown requires that record to be identical afterward.
# The viewer command attaches or detaches one real foreground Herdr client on
# an owned lab session over a fixed 40-row by 120-column pty;
# bin/jg-herdr-lab-viewer.py owns the pty mechanics.
# Start succeeds only when that session reports a foreground client and the
# recorded viewer process still matches its launch identity.
# Stop signals only identity-matched recorded processes and retains its
# ownership record until detach is confirmed or the session is stopped or
# absent; teardown refuses when that stop cannot be confirmed.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -u

jg_herdr_lab_error() {
  echo "jg-herdr-lab: $*" >&2
}

jg_herdr_lab_validate_name() { # <session>
  local name=${1:-}
  [[ "$name" =~ ^jg-lab-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] && return 0
  case "$name" in
    default) jg_herdr_lab_error "refusing session name 'default'" ;;
    '') jg_herdr_lab_error "refusing an empty session name" ;;
    *) jg_herdr_lab_error "session name must start with 'jg-lab-' and contain only letters, digits, underscores, or dashes: $name" ;;
  esac
  return 1
}

jg_herdr_lab_state_dir() {
  printf '%s' "${JG_HERDR_LAB_STATE_DIR:-${TMPDIR:-/tmp}/jg-herdr-lab-${UID}}"
}

jg_herdr_lab_tripwire_path() { # <session>
  printf '%s/%s.fleet-state.json' "$(jg_herdr_lab_state_dir)" "$1"
}

jg_herdr_lab_private_dir() {
  local mode
  [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] || return 1
  case "$(uname -s)" in
    Darwin) mode=$(stat -f '%Lp' "$1") || return 1 ;;
    *) mode=$(stat -c '%a' "$1") || return 1 ;;
  esac
  [ "$mode" = 700 ]
}

jg_herdr_lab_ensure_state() {
  local dir
  dir=$(jg_herdr_lab_state_dir)
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    (umask 077; mkdir -p "$dir") || return 1
  fi
  jg_herdr_lab_private_dir "$dir" || {
    jg_herdr_lab_error "lab state must be an owned, non-symlink directory with mode 700: $dir"
    return 1
  }
}

jg_herdr_lab_xdg_base() { # <session>
  local pointer base
  jg_herdr_lab_validate_name "$1" || return 1
  jg_herdr_lab_ensure_state || return 1
  pointer="$(jg_herdr_lab_state_dir)/$1.xdg-root"
  [ -f "$pointer" ] && [ ! -L "$pointer" ] && [ -O "$pointer" ] || {
    jg_herdr_lab_error "missing or unsafe disposable root for '$1'; fresh provisioning required"
    return 1
  }
  base=$(cat "$pointer") || return 1
  [[ "$base" =~ ^/tmp/fhl\.[a-zA-Z0-9]{6}$ ]] && jg_herdr_lab_private_dir "$base" \
    && [ -f "$base/.lab-session" ] && [ ! -L "$base/.lab-session" ] \
    && [ "$(cat "$base/.lab-session")" = "$1" ] || {
    jg_herdr_lab_error "invalid disposable root identity for '$1'"
    return 1
  }
  printf '%s' "$base"
}

# Prints the session's isolated base after creating its disposable directories.
jg_herdr_lab_ensure_isolated_xdg() { # <session>
  local base pointer sub
  jg_herdr_lab_validate_name "$1" || return 1
  jg_herdr_lab_ensure_state || return 1
  pointer="$(jg_herdr_lab_state_dir)/$1.xdg-root"
  if [ ! -e "$pointer" ] && [ ! -L "$pointer" ]; then
    [ ! -e "$(jg_herdr_lab_state_dir)/$1.xdg" ] && [ ! -L "$(jg_herdr_lab_state_dir)/$1.xdg" ] || {
      jg_herdr_lab_error "legacy XDG root for '$1'; guarded cleanup and fresh provisioning required"
      return 1
    }
    base=$(mktemp -d /tmp/fhl.XXXXXX) || return 1
    printf '%s\n' "$1" > "$base/.lab-session" || return 1
    if ! (umask 077; set -o noclobber; printf '%s\n' "$base" > "$pointer") 2>/dev/null; then
      rm -f "$base/.lab-session"
      rmdir "$base"
    fi
  fi
  base=$(jg_herdr_lab_xdg_base "$1") || return 1
  for sub in home config data state cache; do
    if [ -L "$base/$sub" ] || { [ -e "$base/$sub" ] && ! jg_herdr_lab_private_dir "$base/$sub"; }; then
      jg_herdr_lab_error "unsafe disposable directory: $base/$sub"
      return 1
    fi
  done
  (umask 077; mkdir -p "$base/home" "$base/config" "$base/data" "$base/state" "$base/cache") || {
    jg_herdr_lab_error "cannot create isolated XDG directories under $base"
    return 1
  }
  printf '%s' "$base"
}

jg_herdr_lab_runtime_env() {
  local name=$1 base key
  base=$(jg_herdr_lab_ensure_isolated_xdg "$name") || return 1
  for key in $(compgen -e); do
    case "$key" in CLAUDE_*|ANTHROPIC_*|OPENAI_API_KEY|PI_CODING_AGENT_DIR|CODEX_HOME) unset "$key" || return 1 ;; esac
  done
  export HOME="$base/home" XDG_CONFIG_HOME="$base/config" XDG_DATA_HOME="$base/data" \
    XDG_STATE_HOME="$base/state" XDG_CACHE_HOME="$base/cache" \
    CLAUDE_CONFIG_DIR="$base/home/.claude" PI_CODING_AGENT_DIR="$base/home/.pi/agent" \
    CODEX_HOME="$base/home/.codex" HERDR_SESSION="$name"
}

jg_herdr_lab_env() ( # <session> <command...>
  jg_herdr_lab_runtime_env "$1" || return 1
  shift
  exec "$@"
)

jg_herdr_lab_exec() { # <session> <herdr arguments...>
  local name=$1
  shift
  jg_herdr_lab_env "$name" herdr "$@"
}

jg_herdr_lab_raw() { # <session> <herdr arguments...>
  local name=$1 i
  shift
  local -a args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    [ "${args[i]}" = -- ] || continue
    jg_herdr_lab_exec "$name" "${args[@]:0:i}" --session "$name" "${args[@]:i}"
    return
  done
  jg_herdr_lab_exec "$name" "$@" --session "$name"
}

jg_herdr_lab_session_list() { # <session>
  jg_herdr_lab_raw "$1" session list --json
}

# Fleet observation never changes the named runtime's HOME or XDG context.
jg_herdr_lab_fleet_session_list() ( # <session>
  if [ "${JG_HERDR_LAB_FLEET_HOME+x}" = x ]; then
    case "$JG_HERDR_LAB_FLEET_HOME" in
      /*) ;;
      *) jg_herdr_lab_error "fleet HOME must be an existing absolute directory"; return 1 ;;
    esac
    [ -d "$JG_HERDR_LAB_FLEET_HOME" ] || {
      jg_herdr_lab_error "fleet HOME must be an existing absolute directory"
      return 1
    }
    export HOME="$JG_HERDR_LAB_FLEET_HOME"
    unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
  fi
  HERDR_SESSION="$1" herdr session list --json --session "$1"
)

jg_herdr_lab_fleet_state() { # <session>
  local name=$1 sessions snapshot
  sessions=$(jg_herdr_lab_fleet_session_list "$name" 2>/dev/null) || {
    jg_herdr_lab_error "cannot read Herdr sessions for the fleet-state tripwire"
    return 1
  }
  snapshot=$(printf '%s' "$sessions" | jq -c '
    [.sessions[]? | select(.default == true)]
    | if length == 1 and .[0].name == "default" and .[0].running == true
      then .[0] | {name, default, running, socket_path}
      else empty
      end
  ' 2>/dev/null)
  [ -n "$snapshot" ] || {
    jg_herdr_lab_error "fleet-state tripwire requires exactly one running default session"
    return 1
  }
  printf '%s\n' "$snapshot"
}

jg_herdr_lab_prepare() { # <session>
  local name=$1 sessions tripwire
  jg_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { jg_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { jg_herdr_lab_error "jq is required"; return 1; }

  sessions=$(jg_herdr_lab_session_list "$name" 2>/dev/null) || {
    jg_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    jg_herdr_lab_error "session '$name' already exists; refusing to adopt or overwrite it"
    return 1
  fi

  tripwire=$(jg_herdr_lab_tripwire_path "$name")
  jg_herdr_lab_ensure_state || return 1
  [ ! -e "$tripwire" ] || {
    jg_herdr_lab_error "tripwire already exists for '$name'; refusing ambiguous ownership"
    return 1
  }
  jg_herdr_lab_fleet_state "$name" > "$tripwire" || {
    rm -f "$tripwire"
    return 1
  }
}

jg_herdr_lab_refuse_if_default() { # <session>
  local name=$1 info flag
  jg_herdr_lab_validate_name "$name" || return 1
  info=$(jg_herdr_lab_session_list "$name" 2>/dev/null) || {
    jg_herdr_lab_error "refusing destructive call because session list failed"
    return 1
  }
  flag=$(printf '%s' "$info" | jq -r --arg name "$name" \
    '.sessions[]? | select(.name == $name) | .default' 2>/dev/null)
  [ "$flag" = false ] && return 0
  jg_herdr_lab_error "refusing destructive call for '$name': session is absent or default (default=${flag:-<not found>})"
  return 1
}

jg_herdr_lab_cli() { # <session> <herdr arguments...>
  local name=$1 arg
  shift
  jg_herdr_lab_validate_name "$name" || return 1
  [ "$#" -gt 0 ] || { jg_herdr_lab_error "run requires Herdr arguments"; return 1; }
  case "$1" in
    -*)
      jg_herdr_lab_error "run forbids a leading option before the Herdr subcommand; it could shift a server or session lifecycle operation past the guard or subvert session isolation"
      return 1
      ;;
  esac
  for arg in "$@"; do
    case "$arg" in
      --session|--session=*)
        jg_herdr_lab_error "run forbids caller-supplied --session; the helper supplies the lab session"
        return 1
        ;;
    esac
  done
  case "$1 ${2:-}" in
    "server "*)
      jg_herdr_lab_error "run forbids server operations; use provision for the named lab server"
      return 1
      ;;
    "session list") ;;
    "session "*)
      jg_herdr_lab_error "run forbids session lifecycle operations; use guarded teardown"
      return 1
      ;;
  esac
  jg_herdr_lab_raw "$name" "$@"
}

# --- foreground viewer ------------------------------------------------------
#
# Herdr counts a client as the session's foreground viewer only once that
# client reports a usable window grid, so a zero-sized pty attaches nothing and
# leaves `terminal title clear` answering no_foreground_client. Attaching a
# real viewer is what lets a test drive the live-client teardown paths instead
# of only their detached halves. bin/jg-herdr-lab-viewer.py owns the pty and
# environment mechanics; the guards below own who may be attached to.
# Per-session locks are deliberately absent: generated jg-lab-<label>-$$-$RANDOM
# names have no caller that starts one viewer concurrently, so locks add risk.
# A subsecond interrupt window and SIGKILL residue are accepted in this isolated
# lab helper because teardown drops any stray viewer connection with the session.

readonly jg_herdr_lab_viewer_timeout_seconds=5
readonly jg_herdr_lab_viewer_launcher_grace_seconds=6

jg_herdr_lab_viewer_record_path() { # <session>
  printf '%s/%s.viewer' "$(jg_herdr_lab_state_dir)" "$1"
}

jg_herdr_lab_viewer_log_path() { # <session>
  printf '%s/%s.viewer.log' "$(jg_herdr_lab_state_dir)" "$1"
}

jg_herdr_lab_viewer_launcher_path() {
  printf '%s/jg-herdr-lab-viewer.py' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

# Prints the session's current foreground-client reason, or nothing when it
# cannot be read.
jg_herdr_lab_viewer_reason() { # <session>
  local name=$1 out
  out=$(jg_herdr_lab_cli "$name" terminal title clear 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '.result.reason // empty' 2>/dev/null
}

jg_herdr_lab_process_start() { # <pid>
  LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

jg_herdr_lab_process_parent() { # <pid>
  LC_ALL=C ps -p "$1" -o ppid= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

jg_herdr_lab_viewer_recorded_value() { # <session> <key>
  local record value
  record=$(jg_herdr_lab_viewer_record_path "$1")
  [ -f "$record" ] || return 1
  value=$(sed -n "s/^$2=//p" "$record" | head -n 1)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

jg_herdr_lab_viewer_owned_pair() { # <session>
  local launcher_pid viewer_pid launcher_start viewer_start current_start parent_pid
  launcher_pid=$(jg_herdr_lab_viewer_recorded_value "$1" launcher_pid) || return 1
  viewer_pid=$(jg_herdr_lab_viewer_recorded_value "$1" viewer_pid) || return 1
  case "$launcher_pid:$viewer_pid" in
    *[!0-9:]*) return 1 ;;
  esac
  launcher_start=$(jg_herdr_lab_viewer_recorded_value "$1" launcher_start) || return 1
  viewer_start=$(jg_herdr_lab_viewer_recorded_value "$1" viewer_start) || return 1
  current_start=$(jg_herdr_lab_process_start "$launcher_pid") || return 1
  [ -n "$current_start" ] && [ "$current_start" = "$launcher_start" ] || return 1
  current_start=$(jg_herdr_lab_process_start "$viewer_pid") || return 1
  [ -n "$current_start" ] && [ "$current_start" = "$viewer_start" ] || return 1
  parent_pid=$(jg_herdr_lab_process_parent "$viewer_pid") || return 1
  [ "$parent_pid" = "$launcher_pid" ] || return 1
  printf '%s %s' "$launcher_pid" "$viewer_pid"
}

jg_herdr_lab_viewer_owned_pid() { # <session> <launcher|viewer>
  local pair
  pair=$(jg_herdr_lab_viewer_owned_pair "$1") || return 1
  case "$2" in
    launcher) printf '%s' "${pair%% *}" ;;
    viewer) printf '%s' "${pair#* }" ;;
    *) return 1 ;;
  esac
}

jg_herdr_lab_viewer_signal() { # <session> <launcher|viewer> <signal>
  local pid
  pid=$(jg_herdr_lab_viewer_owned_pid "$1" "$2") || return 0
  kill "-$3" "$pid" 2>/dev/null || true
}

# True while this lab owns a viewer process that is still running.
jg_herdr_lab_viewer_owned_alive() { # <session>
  jg_herdr_lab_viewer_owned_pair "$1" >/dev/null
}

jg_herdr_lab_viewer_session_stopped_or_absent() { # <session>
  local sessions running
  sessions=$(jg_herdr_lab_session_list "$1" 2>/dev/null) || return 1
  running=$(printf '%s' "$sessions" | jq -r --arg name "$1" \
    '[.sessions[]? | select(.name == $name) | .running] | if length == 0 then "absent" elif length == 1 then .[0] else "ambiguous" end' \
    2>/dev/null) || return 1
  [ "$running" = false ] || [ "$running" = absent ]
}

jg_herdr_lab_viewer_start() { # <session>
  local name=$1 record log launcher launcher_pid waited attempt reason pid interrupt_traps=0 timeout=$jg_herdr_lab_viewer_timeout_seconds
  jg_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { jg_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { jg_herdr_lab_error "jq is required"; return 1; }
  command -v python3 >/dev/null 2>&1 || { jg_herdr_lab_error "python3 is required for the lab viewer"; return 1; }

  [ -f "$(jg_herdr_lab_tripwire_path "$name")" ] || {
    jg_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing to attach a viewer to a session this lab does not own"
    return 1
  }
  jg_herdr_lab_refuse_if_default "$name" || return 1

  record=$(jg_herdr_lab_viewer_record_path "$name")
  if jg_herdr_lab_viewer_owned_alive "$name"; then
    jg_herdr_lab_error "a lab viewer is already attached to '$name'; stop it before starting another"
    return 1
  fi
  rm -f "$record"

  launcher=$(jg_herdr_lab_viewer_launcher_path)
  [ -f "$launcher" ] || { jg_herdr_lab_error "missing viewer launcher at $launcher"; return 1; }
  log=$(jg_herdr_lab_viewer_log_path "$name")
  mkdir -p "$(jg_herdr_lab_state_dir)" || return 1
  launcher_pid=
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    interrupt_traps=1
    trap 'trap - INT TERM; [ -z "${launcher_pid:-}" ] || jg_herdr_lab_cancel_viewer_launcher "$launcher_pid"; exit 130' INT
    trap 'trap - INT TERM; [ -z "${launcher_pid:-}" ] || jg_herdr_lab_cancel_viewer_launcher "$launcher_pid"; exit 143' TERM
  fi
  (jg_herdr_lab_runtime_env "$name" && exec nohup python3 "$launcher" "$name" "$record") >"$log" 2>&1 &
  launcher_pid=$!

  waited=0
  attempt=$((timeout * 5))
  while [ "$waited" -lt "$attempt" ]; do
    reason=$(jg_herdr_lab_viewer_reason "$name") || reason=
    if [ "$reason" = cleared ]; then
      pid=$(jg_herdr_lab_viewer_owned_pid "$name" viewer) || pid=
      if [ -n "$pid" ]; then
        [ "$interrupt_traps" = 0 ] || trap - INT TERM
        disown "$launcher_pid" 2>/dev/null || true
        printf 'viewer attached to %s (pid %s)\n' "$name" "$pid"
        return 0
      fi
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  jg_herdr_lab_cancel_viewer_launcher "$launcher_pid"
  [ "$interrupt_traps" = 0 ] || trap - INT TERM
  jg_herdr_lab_error "lab viewer did not become the foreground client of '$name' within $timeout seconds (last reason: ${reason:-<unreadable>})"
  [ ! -s "$log" ] || jg_herdr_lab_error "viewer log: $(tail -n 5 "$log" | tr '\n' ' ')"
  jg_herdr_lab_viewer_stop "$name" >/dev/null 2>&1 || true
  return 1
}

jg_herdr_lab_viewer_stop() { # <session>
  local name=$1 record log role waited attempt reason timeout=$jg_herdr_lab_viewer_timeout_seconds
  jg_herdr_lab_validate_name "$name" || return 1
  jg_herdr_lab_xdg_base "$name" >/dev/null || return 1
  record=$(jg_herdr_lab_viewer_record_path "$name")
  log=$(jg_herdr_lab_viewer_log_path "$name")
  # An absent record means this lab owns no viewer. Any client attached in that
  # case belongs to someone else and must never be signalled from here.
  [ -f "$record" ] || return 0

  for role in viewer launcher; do
    jg_herdr_lab_viewer_signal "$name" "$role" TERM
  done
  waited=0
  while jg_herdr_lab_viewer_owned_alive "$name" && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  for role in viewer launcher; do
    jg_herdr_lab_viewer_signal "$name" "$role" KILL
  done

  waited=0
  attempt=$((timeout * 5))
  while [ "$waited" -lt "$attempt" ]; do
    reason=$(jg_herdr_lab_viewer_reason "$name") || reason=
    if [ "$reason" = no_foreground_client ] \
      || { [ -z "$reason" ] && jg_herdr_lab_viewer_session_stopped_or_absent "$name"; }; then
      rm -f "$record" "$log"
      return 0
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  jg_herdr_lab_error "lab viewer for '$name' did not detach within $timeout seconds (last reason: ${reason:-<unreadable>})"
  return 1
}

jg_herdr_lab_viewer() { # <start|stop> <session>
  case "${1:-}" in
    start) jg_herdr_lab_viewer_start "$2" ;;
    stop) jg_herdr_lab_viewer_stop "$2" ;;
    *)
      jg_herdr_lab_error "viewer takes 'start' or 'stop'"
      return 2
      ;;
  esac
}

jg_herdr_lab_cancel_viewer_launcher() { # <pid>
  local pid=$1 attempt=0 max_attempts=$((jg_herdr_lab_viewer_launcher_grace_seconds * 10))
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt "$max_attempts" ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

jg_herdr_lab_cancel_provision() { # <pid>
  local pid=$1 attempt=0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 10 ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

jg_herdr_lab_provision() { # <session>
  local name=$1 sessions tripwire running attempt server_pid max_attempts timeout_seconds
  jg_herdr_lab_validate_name "$name" || return 1
  command -v herdr >/dev/null 2>&1 || { jg_herdr_lab_error "herdr is required"; return 1; }
  command -v jq >/dev/null 2>&1 || { jg_herdr_lab_error "jq is required"; return 1; }

  sessions=$(jg_herdr_lab_session_list "$name" 2>/dev/null) || {
    jg_herdr_lab_error "cannot list Herdr sessions before provisioning '$name'"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    tripwire=$(jg_herdr_lab_tripwire_path "$name")
    [ -f "$tripwire" ] || {
      jg_herdr_lab_error "missing fleet-state tripwire for existing session '$name'; refusing to adopt it"
      return 1
    }
    jg_herdr_lab_refuse_if_default "$name" || return 1
    running=$(printf '%s' "$sessions" | jq -r --arg name "$name" \
      '.sessions[]? | select(.name == $name) | .running' 2>/dev/null)
    [ "$running" = false ] || {
      jg_herdr_lab_error "session '$name' is not stopped; refusing to re-provision it"
      return 1
    }
    jg_herdr_lab_check_tripwire "$name" || return 1
  else
    jg_herdr_lab_prepare "$name" || return 1
  fi
  (jg_herdr_lab_runtime_env "$name" && exec herdr server --session "$name") >/dev/null 2>&1 &
  server_pid=$!
  attempt=0
  max_attempts=300
  timeout_seconds=60
  while [ "$attempt" -lt "$max_attempts" ]; do
    running=$(jg_herdr_lab_cli "$name" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null) || running=false
    if [ "$running" = true ]; then
      jg_herdr_lab_refuse_if_default "$name" || {
        jg_herdr_lab_cancel_provision "$server_pid"
        return 1
      }
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done
  jg_herdr_lab_cancel_provision "$server_pid"
  jg_herdr_lab_error "lab session '$name' did not report running within $timeout_seconds seconds"
  return 1
}

jg_herdr_lab_check_tripwire() { # <session>
  local name=$1 tripwire before after
  jg_herdr_lab_ensure_state || return 1
  tripwire=$(jg_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    jg_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing unverified teardown"
    return 1
  }
  before=$(cat "$tripwire")
  after=$(jg_herdr_lab_fleet_state "$name") || return 1
  [ "$before" = "$after" ] || {
    jg_herdr_lab_error "FLEET-STATE TRIPWIRE FAILED: default session changed during lab work"
    jg_herdr_lab_error "before: $before"
    jg_herdr_lab_error "after:  $after"
    return 1
  }
}

jg_herdr_lab_verify_tripwire() { # <session>
  local name=$1 tripwire
  jg_herdr_lab_check_tripwire "$name" || return 1
  tripwire=$(jg_herdr_lab_tripwire_path "$name")
  rm -f "$tripwire"
}

jg_herdr_lab_stop() { # <session>
  local name=$1 tripwire
  jg_herdr_lab_validate_name "$name" || return 1
  tripwire=$(jg_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    jg_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing stop"
    return 1
  }
  jg_herdr_lab_refuse_if_default "$name" || return 1
  jg_herdr_lab_raw "$name" session stop "$name" --json
}

jg_herdr_lab_teardown() { # <session>
  local name=$1 tripwire sessions base delete_status=0
  jg_herdr_lab_validate_name "$name" || return 1
  base=$(jg_herdr_lab_xdg_base "$name") || return 1
  tripwire=$(jg_herdr_lab_tripwire_path "$name")
  [ -f "$tripwire" ] || {
    jg_herdr_lab_error "missing fleet-state tripwire for '$name'; refusing destructive calls"
    return 1
  }
  jg_herdr_lab_viewer_stop "$name" || {
    jg_herdr_lab_error "refusing teardown of '$name' while this lab's viewer is still attached"
    return 1
  }
  sessions=$(jg_herdr_lab_session_list "$name" 2>/dev/null) || {
    jg_herdr_lab_error "cannot list Herdr sessions before teardown"
    return 1
  }
  if ! printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    jg_herdr_lab_verify_tripwire "$name" || return 1
    rm -rf "$base"
    rm -f "$(jg_herdr_lab_state_dir)/$name.xdg-root"
    return
  fi
  jg_herdr_lab_stop "$name" >/dev/null 2>&1 || true
  sleep 0.5
  jg_herdr_lab_refuse_if_default "$name" || return 1
  jg_herdr_lab_raw "$name" session delete "$name" --json >/dev/null 2>&1 || delete_status=$?
  sessions=$(jg_herdr_lab_session_list "$name" 2>/dev/null) || {
    jg_herdr_lab_error "cannot confirm removal of lab session '$name' after teardown"
    return 1
  }
  if printf '%s' "$sessions" | jq -e --arg name "$name" '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    if [ "$delete_status" -ne 0 ]; then
      jg_herdr_lab_error "session delete failed for '$name' and the lab session remains"
    else
      jg_herdr_lab_error "lab session '$name' remains after teardown"
    fi
    return 1
  fi
  jg_herdr_lab_verify_tripwire "$name" || return 1
  rm -rf "$base"
  rm -f "$(jg_herdr_lab_state_dir)/$name.xdg-root"
}

jg_herdr_lab_name() { # <label>
  local label=${1:-lab}
  label=$(printf '%s' "$label" | tr -cd 'a-zA-Z0-9_-' | sed 's/^[^a-zA-Z0-9]*//; s/-*$//')
  [ -n "$label" ] || label=lab
  label=${label:0:16}
  label=${label%-}
  [ -n "$label" ] || label=lab
  printf 'jg-lab-%s-%s-%s\n' "$label" "$$" "$RANDOM"
}

jg_herdr_lab_usage() {
  sed -n '2,/^set -u/{ /^set -u/d; p; }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

jg_herdr_lab_main() {
  local command=${1:-}
  if [ "$command" = --isolated-xdg ]; then
    shift
    command=${1:-}
  fi
  case "$command" in
    name)
      [ "$#" -eq 2 ] || { jg_herdr_lab_usage >&2; return 2; }
      jg_herdr_lab_name "$2"
      ;;
    prepare)
      [ "$#" -eq 2 ] || { jg_herdr_lab_usage >&2; return 2; }
      jg_herdr_lab_prepare "$2"
      ;;
    provision)
      [ "$#" -eq 2 ] || { jg_herdr_lab_usage >&2; return 2; }
      jg_herdr_lab_provision "$2"
      ;;
    run)
      [ "$#" -ge 3 ] || { jg_herdr_lab_usage >&2; return 2; }
      shift
      jg_herdr_lab_cli "$@"
      ;;
    viewer)
      [ "$#" -eq 3 ] || { jg_herdr_lab_usage >&2; return 2; }
      jg_herdr_lab_viewer "$2" "$3"
      ;;
    stop)
      [ "$#" -eq 2 ] || { jg_herdr_lab_usage >&2; return 2; }
      jg_herdr_lab_stop "$2"
      ;;
    teardown)
      [ "$#" -eq 2 ] || { jg_herdr_lab_usage >&2; return 2; }
      jg_herdr_lab_teardown "$2"
      ;;
    -h|--help|help)
      jg_herdr_lab_usage
      ;;
    *)
      jg_herdr_lab_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  jg_herdr_lab_main "$@"
fi
