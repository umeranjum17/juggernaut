#!/usr/bin/env bash
# Provision and operate an isolated Herdr Core (hc) lab session without any
# risk to the fleet's own Herdr Core.
#
# Usage:
#   jg-hc-lab.sh name <label>
#   jg-hc-lab.sh provision <session>
#   jg-hc-lab.sh run <session> <hc arguments...>
#   jg-hc-lab.sh stop <session>
#   jg-hc-lab.sh teardown <session>
#
# Isolation is by path, not by name alone. Herdr Core keeps one core's socket,
# holder sockets and state under XDG_RUNTIME_DIR and XDG_STATE_HOME, named by
# HC_SESSION, and a core whose XDG_RUNTIME_DIR is not /run/user/<uid> never
# registers a systemd user service (herdr-core 0.1.18, crates/herdr-core/src
# paths.rs and platform/systemd.rs). Every hc call made here therefore runs with
# HC_SESSION=<session> and a private HOME, XDG_RUNTIME_DIR, XDG_CONFIG_HOME,
# XDG_DATA_HOME, XDG_STATE_HOME and XDG_CACHE_HOME under one disposable
# /tmp/fhc.<six alphanumerics> root, with HC_SOCKET unset, so no call can reach
# another core. The root is recorded by <session>.root in the lab state
# directory (JG_HC_LAB_STATE_DIR, default ${TMPDIR:-/tmp}/jg-hc-lab-<uid>).
# Credentials never enter: exported CLAUDE_*, ANTHROPIC_*, OPENAI_API_KEY,
# PI_CODING_AGENT_DIR and CODEX_HOME are cleared, and CLAUDE_CONFIG_DIR,
# PI_CODING_AGENT_DIR and CODEX_HOME point under the disposable home.
# State and disposable directories must be owned, non-symlink, and mode 700.
#
# Session names must begin with "jg-hclab-" and can never be "default"; the
# name command sanitizes the label, caps it at 16 characters, and appends
# process and random suffixes so socket paths stay short.
# The run command refuses a leading option and the subcommands that act on a
# core or on other machines: server, update, machine and connect. Starting and
# stopping the lab core is only provision, stop and teardown.
# Provision records the fleet's default Herdr Core socket identity
# (<session>.fleet-state) as a tripwire, and teardown requires it unchanged.
# Teardown ends every lab terminal, stops the lab core, waits for the exact core
# and holder processes it recorded to exit, then removes the disposable root.
# JG_HC_LAB_BIN names the Herdr Core binary (default: hc on PATH).
# docs/hc-backend.md owns why this helper exists beside jg-herdr-lab.sh.
set -u

jg_hc_lab_error() {
  echo "jg-hc-lab: $*" >&2
}

jg_hc_lab_bin() {
  printf '%s' "${JG_HC_LAB_BIN:-hc}"
}

jg_hc_lab_validate_name() { # <session>
  local name=${1:-}
  if [[ "$name" =~ ^jg-hclab-[a-z0-9_-]+$ ]] && [ "${#name}" -le 40 ]; then
    return 0
  fi
  case "$name" in
    default) jg_hc_lab_error "refusing session name 'default'" ;;
    '') jg_hc_lab_error "refusing an empty session name" ;;
    *) jg_hc_lab_error "session name must start with 'jg-hclab-', use only a-z 0-9 _ -, and stay within 40 characters: $name" ;;
  esac
  return 1
}

jg_hc_lab_name() { # <label>
  local label suffix
  label=$(printf '%s' "${1:-lab}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_\n-' '-' | tr -d '\n')
  label=${label:0:16}
  [ -n "$label" ] || label=lab
  suffix=$(printf '%s' "$$-${RANDOM}${RANDOM}" | tr -c '0-9-' '-')
  printf 'jg-hclab-%s-%s' "$label" "${suffix:0:12}"
}

jg_hc_lab_state_dir() {
  printf '%s' "${JG_HC_LAB_STATE_DIR:-${TMPDIR:-/tmp}/jg-hc-lab-${UID}}"
}

jg_hc_lab_private_dir() { # <dir>
  local mode
  [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] || return 1
  case "$(uname -s)" in
    Darwin) mode=$(stat -f '%Lp' "$1") || return 1 ;;
    *) mode=$(stat -c '%a' "$1") || return 1 ;;
  esac
  [ "$mode" = 700 ]
}

jg_hc_lab_ensure_state() {
  local dir
  dir=$(jg_hc_lab_state_dir)
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    (umask 077; mkdir -p "$dir") || return 1
  fi
  jg_hc_lab_private_dir "$dir" || {
    jg_hc_lab_error "lab state must be an owned, non-symlink directory with mode 700: $dir"
    return 1
  }
}

# The provisioned root of <session>, after proving its identity.
jg_hc_lab_root() { # <session>
  local pointer root sub
  jg_hc_lab_validate_name "$1" || return 1
  jg_hc_lab_ensure_state || return 1
  pointer="$(jg_hc_lab_state_dir)/$1.root"
  [ -f "$pointer" ] && [ ! -L "$pointer" ] && [ -O "$pointer" ] || {
    jg_hc_lab_error "session '$1' is not provisioned here"
    return 1
  }
  root=$(cat "$pointer") || return 1
  [[ "$root" =~ ^/tmp/fhc\.[a-zA-Z0-9]{6}$ ]] && jg_hc_lab_private_dir "$root" \
    && [ -f "$root/.lab-session" ] && [ ! -L "$root/.lab-session" ] \
    && [ "$(cat "$root/.lab-session")" = "$1" ] || {
    jg_hc_lab_error "invalid disposable root identity for '$1'"
    return 1
  }
  for sub in run home config data state cache; do
    jg_hc_lab_private_dir "$root/$sub" || {
      jg_hc_lab_error "unsafe disposable directory: $root/$sub"
      return 1
    }
  done
  printf '%s' "$root"
}

# Runs <command...> with the lab's isolated environment; a subshell, so the
# caller's environment is never changed.
jg_hc_lab_env() ( # <session> <command...>
  local root key
  root=$(jg_hc_lab_root "$1") || exit 1
  for key in $(compgen -e); do
    case "$key" in CLAUDE_*|ANTHROPIC_*|OPENAI_API_KEY|PI_CODING_AGENT_DIR|CODEX_HOME|HC_*) unset "$key" || exit 1 ;; esac
  done
  # shellcheck disable=SC2030 # Deliberately local: only the exec'd hc sees the lab paths.
  export HC_SESSION="$1" HOME="$root/home" XDG_RUNTIME_DIR="$root/run" \
    XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data" XDG_STATE_HOME="$root/state" \
    XDG_CACHE_HOME="$root/cache" CLAUDE_CONFIG_DIR="$root/home/.claude" \
    PI_CODING_AGENT_DIR="$root/home/.pi/agent" CODEX_HOME="$root/home/.codex"
  shift
  # Every signal at its default action, as jg_backend_hc_default_signals
  # (bin/backends/hc.sh) explains: the core this may start, and every lab
  # program, would otherwise inherit a background caller's ignored SIGINT.
  if env --default-signal true >/dev/null 2>&1; then
    exec env --default-signal "$@"
  fi
  exec python3 -I -c 'import os, signal, sys
for s in signal.valid_signals():
    try: signal.signal(s, signal.SIG_DFL)
    except (OSError, ValueError): pass
os.execvp(sys.argv[1], sys.argv[1:])' "$@"
)

jg_hc_lab_hc() { # <session> <hc arguments...>
  local name=$1
  shift
  jg_hc_lab_env "$name" "$(jg_hc_lab_bin)" "$@"
}

# The fleet's default core as the caller's own environment would reach it.
jg_hc_lab_fleet_socket() {
  # shellcheck disable=SC2031 # The caller's own value, never the lab subshell's.
  local run=${XDG_RUNTIME_DIR:-/run/user/$UID}
  printf '%s' "${HC_SOCKET:-$run/herdr-core/default.sock}"
}

jg_hc_lab_fleet_state() {
  local socket inode
  socket=$(jg_hc_lab_fleet_socket)
  if [ -e "$socket" ] || [ -L "$socket" ]; then
    case "$(uname -s)" in
      Darwin) inode=$(stat -f '%i' "$socket") || return 1 ;;
      *) inode=$(stat -c '%i' "$socket") || return 1 ;;
    esac
    printf 'present %s %s\n' "$socket" "$inode"
  else
    printf 'absent %s\n' "$socket"
  fi
}

# A fresh refuse-default check before any call that stops a core.
jg_hc_lab_refuse_default() { # <session>
  local root
  jg_hc_lab_validate_name "$1" || return 1
  root=$(jg_hc_lab_root "$1") || return 1
  case "$root/run" in
    "/run/user/"*) jg_hc_lab_error "refusing: lab runtime directory is the user's own"; return 1 ;;
  esac
  [ -S "$root/run/herdr-core/$1.sock" ] || [ ! -e "$root/run/herdr-core/$1.sock" ] || {
    jg_hc_lab_error "refusing: lab socket path is not a socket"
    return 1
  }
}

jg_hc_lab_provision() { # <session>
  local name=$1 dir pointer tripwire root status version
  jg_hc_lab_validate_name "$name" || return 1
  command -v "$(jg_hc_lab_bin)" >/dev/null 2>&1 || {
    jg_hc_lab_error "Herdr Core binary not found: $(jg_hc_lab_bin)"
    return 1
  }
  jg_hc_lab_ensure_state || return 1
  dir=$(jg_hc_lab_state_dir)
  pointer="$dir/$name.root"
  tripwire="$dir/$name.fleet-state"
  if [ ! -e "$tripwire" ]; then
    jg_hc_lab_fleet_state > "$tripwire" || {
      jg_hc_lab_error "cannot record the fleet Herdr Core tripwire"
      return 1
    }
  fi
  if [ ! -e "$pointer" ] && [ ! -L "$pointer" ]; then
    root=$(mktemp -d /tmp/fhc.XXXXXX) || return 1
    chmod 700 "$root" || return 1
    printf '%s\n' "$name" > "$root/.lab-session" || return 1
    (umask 077; mkdir "$root/run" "$root/home" "$root/config" "$root/data" "$root/state" "$root/cache") || return 1
    (umask 077; set -o noclobber; printf '%s\n' "$root" > "$pointer") || {
      jg_hc_lab_error "cannot record the lab root for '$name'"
      return 1
    }
  fi
  root=$(jg_hc_lab_root "$name") || return 1
  # `server status` starts the core when none listens (client.rs connect_or_start).
  status=$(jg_hc_lab_hc "$name" server status --json 2>&1) || {
    jg_hc_lab_error "lab core did not start: $status"
    return 1
  }
  version=$(printf '%s' "$status" | jq -r '.version // empty' 2>/dev/null)
  [ -n "$version" ] && [ -S "$root/run/herdr-core/$name.sock" ] || {
    jg_hc_lab_error "lab core is not listening inside its own root: $status"
    return 1
  }
}

jg_hc_lab_run() { # <session> <hc arguments...>
  local name=$1
  shift
  jg_hc_lab_root "$name" >/dev/null || return 1
  [ "$#" -gt 0 ] || { jg_hc_lab_error "run needs an hc subcommand"; return 1; }
  case "$1" in
    -*) jg_hc_lab_error "refusing a leading option before the subcommand: $1"; return 1 ;;
    server|update|machine|connect)
      jg_hc_lab_error "refusing '$1' through run; use provision, stop, or teardown"
      return 1
      ;;
  esac
  jg_hc_lab_hc "$name" "$@"
}

jg_hc_lab_stop() { # <session>
  jg_hc_lab_refuse_default "$1" || return 1
  [ -S "$(jg_hc_lab_root "$1")/run/herdr-core/$1.sock" ] || return 0
  jg_hc_lab_hc "$1" server stop --json >/dev/null
}

# Waits for each pid in <pids...> to exit, up to ten seconds in all.
jg_hc_lab_wait_gone() { # <pid...>
  local pid tries=0 alive
  while :; do
    alive=
    for pid in "$@"; do
      kill -0 "$pid" 2>/dev/null && alive="$alive $pid"
    done
    [ -n "$alive" ] || return 0
    [ "$tries" -lt 100 ] || { printf '%s' "$alive"; return 1; }
    sleep 0.1
    tries=$((tries + 1))
  done
}

jg_hc_lab_teardown() { # <session>
  local name=$1 dir root status pids left terminal rc=0
  jg_hc_lab_refuse_default "$name" || return 1
  dir=$(jg_hc_lab_state_dir)
  root=$(jg_hc_lab_root "$name") || return 1
  if [ -S "$root/run/herdr-core/$name.sock" ]; then
    for terminal in $(jg_hc_lab_hc "$name" ls --all --json 2>/dev/null | jq -r '.terminals[]?.address'); do
      jg_hc_lab_hc "$name" kill --json "$terminal" >/dev/null 2>&1 || true
    done
    status=$(jg_hc_lab_hc "$name" server status --json 2>/dev/null) || status='{}'
    pids=$(printf '%s' "$status" | jq -r '[.pid, (.holders[]?.pid)] | map(select(. != null)) | .[]' 2>/dev/null)
    jg_hc_lab_refuse_default "$name" || return 1
    jg_hc_lab_hc "$name" server stop --json >/dev/null || {
      jg_hc_lab_error "lab core stop failed; keeping $root"
      return 1
    }
    # shellcheck disable=SC2086 # one pid per word
    left=$(jg_hc_lab_wait_gone $pids) || {
      jg_hc_lab_error "lab processes still running after stop:$left; keeping $root"
      return 1
    }
  fi
  jg_hc_lab_refuse_default "$name" || return 1
  if ! { rm -rf -- "$root" && rm -f -- "$dir/$name.root"; }; then
    jg_hc_lab_error "cannot remove the lab root $root"
    return 1
  fi
  if [ "$(jg_hc_lab_fleet_state)" != "$(cat "$dir/$name.fleet-state" 2>/dev/null)" ]; then
    jg_hc_lab_error "TRIPWIRE: the fleet Herdr Core socket changed during the lab ($(jg_hc_lab_fleet_socket))"
    rc=1
  fi
  rm -f -- "$dir/$name.fleet-state"
  return "$rc"
}

jg_hc_lab_usage() {
  sed -n '4,10p' "$0" | sed 's/^# \{0,1\}//' >&2
  return 2
}

jg_hc_lab_main() {
  local command=${1:-}
  shift || true
  case "$command:$#" in
    name:0|name:1) jg_hc_lab_name "${1:-}" ;;
    provision:1) jg_hc_lab_provision "$1" ;;
    run:[1-9]*) jg_hc_lab_run "$@" ;;
    stop:1) jg_hc_lab_stop "$1" ;;
    teardown:1) jg_hc_lab_teardown "$1" ;;
    *) jg_hc_lab_usage ;;
  esac
}

jg_hc_lab_main "$@"
