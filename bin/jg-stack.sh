#!/usr/bin/env bash
# jg-stack.sh - the one command that installs, starts and checks the whole stack a home runs on.
#
#   bin/jg-stack.sh [up]      install what is missing, start what is stopped, then report every part
#   bin/jg-stack.sh status    report every part and change nothing
#
# THE PARTS, in the order each one needs the one before it.
#   jg-bus   the Go command that owns the channel, built from core/bus (needs a Go toolchain)
#   tools    nats-server, nats, daprd and ntfy at the versions toolchain.versions pins, installed
#            user-local by bin/jg-bootstrap.sh, the one owner of how a release archive lands
#   nats     the JetStream server and its CAPTAIN stream
#   wake-engine  the Go consumer that brings a home's wake read model up to date for every wake
#            raised on the bus (core/bus/cmd/jg-bus/engine.go), which needs nats
#   router   the Go consumer that routes captain replies by the board's own route, which needs nats
#   dapr     the sidecar, which needs nats
#   ntfy     the delivery server
#   deliver  the CAPTAIN stream's consumer: reads each captain event off the stream and posts it
#            to ntfy, writing state/captain-channel-delivered.jsonl (needs nats and ntfy)
# Each service runs as a systemd user service (installed, enabled, started) when this account has a
# user session whose unit directory is this HOME's; otherwise (CI, a container, a throwaway HOME) the
# same argv is started detached from the home's state/bus directory by `jg-bus.sh serve`.
#
# CONTRACT.
#   report   one line per part: installed <version>, enabled <how>, running pid <n>, listening
#            <address> (wake-engine and router: consuming <stream>/<consumer>, which is
#            confirmed against the server). A second run prints the same lines and changes
#            nothing. `bin/jg-bus.sh probe` prints their stream and consumer counts and handled
#            counters.
#   stop     the first part that cannot be made whole stops the run with exit 1 and ONE line,
#            `STACK_FAILED: <part>: <what is missing>; blocks <what depends on it>`. No later part
#            is attempted, so a half state is never reported as healthy.
#   callers  bin/jg-bootstrap.sh and bin/jg-update.sh run `up`, so a release never lands on a machine
#            without its services; install.sh runs it last.
# Env: JG_HOME, JG_STATE_OVERRIDE; JG_STACK_UNIT_PREFIX (unit names, default jg); JG_STACK_SUPERVISOR
# (auto|systemd|detached); JG_STACK_SKIP=1 makes `up` a no-op for a fixture that must bind no port.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
BUS="$SCRIPT_DIR/jg-bus.sh"
BOOT="$SCRIPT_DIR/jg-bootstrap.sh"
PREFIX=${JG_STACK_UNIT_PREFIX:-jg}
export JG_STACK_UNIT_PREFIX=$PREFIX
export NPM_CONFIG_PREFIX=${NPM_CONFIG_PREFIX:-$HOME/.local}
export PATH=$NPM_CONFIG_PREFIX/bin:$PATH
# shellcheck source=bin/jg-pin-lib.sh
. "$SCRIPT_DIR/jg-pin-lib.sh"

mode=${1:-up}
case $mode in up|status) ;; -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;; *) echo "usage: jg-stack.sh [up|status]" >&2; exit 2 ;; esac
[ "$mode" = status ] || [ "${JG_STACK_SKIP:-0}" != 1 ] || exit 0

fail() {  # <part> <what is missing> <what it blocks>
  printf 'STACK_FAILED: %s: %s; blocks %s\n' "$1" "$2" "$3"
  exit 1
}

# listen_addr <part>: the host:port a part must answer on, read from the same config the services read.
listen_addr() {
  local url
  case $1 in
    nats) url=$("$BUS" config nats-url) ;;
    dapr) printf '127.0.0.1:%s\n' "$("$BUS" config dapr-http-port)"; return ;;
    ntfy) url=$("$BUS" config ntfy-server) ;;
  esac
  url=${url#*://}; url=${url%%/*}
  case $url in *:*) printf '%s\n' "$url" ;; *) printf '%s:4222\n' "$url" ;; esac
}

listening() { ( exec 3<>"/dev/tcp/${1%:*}/${1##*:}" ) 2>/dev/null; }

wait_listening() {  # <addr>
  for _ in $(seq 1 100); do listening "$1" && return 0; sleep 0.2; done
  return 1
}

wait_consumer() {  # <part>: the service has created its consumer on the server
  for _ in $(seq 1 150); do "$BUS" probe "$1" >/dev/null 2>&1 && return 0; sleep 0.2; done
  return 1
}

# The user manager reads units from the account's own home, so a HOME that is not that home (a
# throwaway one) cannot install a unit the manager will see.
supervisor() {
  local want=${JG_STACK_SUPERVISOR:-auto} account_home
  [ "$want" != detached ] || { echo detached; return; }
  if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then echo detached; return; fi
  account_home=$(getent passwd "$(id -u)" | cut -d: -f6)
  [ "$want" = systemd ] || [ "$account_home" = "$HOME" ] || { echo detached; return; }
  echo systemd
}

unit_name() { case $1 in nats) echo "$PREFIX-bus.service" ;; *) echo "$PREFIX-$1.service" ;; esac; }
bin_of() { case $1 in nats|deliver) echo nats-server ;; dapr) echo daprd ;; ntfy) echo ntfy ;; esac; }

# ensure_tool <tool>: at or above its pin, installed from the pinned release when not.
ensure_tool() {
  local tool=$1 want have
  want=$(jg_pin_version "$tool") || fail "$tool" "no row in toolchain.versions" "every service"
  have=$(bash "$BOOT" version "$tool" 2>/dev/null || true)
  if [ -n "$have" ] && [ "$(printf '%s\n%s\n' "$have" "$want" | sort -V | head -n 1)" = "$want" ]; then
    return 0
  fi
  [ "$mode" = up ] || fail "$tool" "not installed at $want or newer" "its service"
  bash "$BOOT" install "$tool" >"$STATE/bus/install-$tool.log" 2>&1 \
    || fail "$tool" "install of the pinned $want failed, see $STATE/bus/install-$tool.log" "its service"
  have=$(bash "$BOOT" version "$tool" 2>/dev/null || true)
  [ -n "$have" ] || fail "$tool" "installed but does not report a version" "its service"
}

# install_unit <part>: write the unit when it differs from the installed one; 0 when it changed.
install_unit() {
  local part=$1 dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user name tmp
  name=$(unit_name "$part")
  mkdir -p "$dir" "$STATE/bus"
  tmp="$STATE/bus/$name.new"
  "$BUS" unit "$part" > "$tmp" || { rm -f -- "$tmp"; fail "$part" "cannot generate its unit" "its service"; }
  if cmp -s "$tmp" "$dir/$name"; then rm -f -- "$tmp"; return 1; fi
  mv -f -- "$tmp" "$dir/$name"
  return 0
}

report() {  # <part> <supervisor>
  local part=$1 sup=$2 name pid=none enabled ver addr=
  name=$(unit_name "$part")
  if consumer_part "$part"; then ver=jg-bus; else ver=$(bash "$BOOT" version "$(bin_of "$part")" 2>/dev/null) || ver=unknown; fi
  # the consumers listen on nothing; their pid proves them
  { consumer_part "$part" || [ "$part" = deliver ]; } || addr=$(listen_addr "$part")
  if [ "$sup" = systemd ]; then
    enabled="$(systemctl --user is-enabled "$name" 2>/dev/null) ($name)"
    pid=$(systemctl --user show -p MainPID --value "$name" 2>/dev/null)
  else
    enabled="n/a, detached (no user session for this HOME)"
    pid=$(cat "$STATE/bus/$part.pid" 2>/dev/null || echo none)
  fi
  if [ -z "$pid" ] || [ "$pid" = 0 ] || ! kill -0 "$pid" 2>/dev/null; then
    fail "$part" "not running (pid ${pid:-none}), see $STATE/bus/$part.log: $(tail -n 2 "$STATE/bus/$part.log" 2>/dev/null | tr '\n' ' ')" "$(blocks "$part")"
  fi
  if [ "$part" = deliver ]; then
    printf '%-7s enabled %s, running pid %s, consuming %s\n' "$part" "$enabled" "$pid" "$("$BUS" config stream)"
    return
  fi
  if consumer_part "$part"; then
    line=$("$BUS" probe "$part" 2>/dev/null) || fail "$part" "running (pid $pid) but its consumer does not exist on the server, see $STATE/bus/$part.log" "$(blocks "$part")"
    printf '%-11s installed %s, enabled %s, running pid %s, consuming %s\n' "$part" "$ver" "$enabled" "$pid" \
      "$(printf '%s\n' "$line" | sed -n 's/.* stream=\([^ ]*\) .* consumer=\([^ ]*\) .*/\1\/\2/p')"
    return
  fi
  listening "$addr" || fail "$part" "running (pid $pid) but not listening on $addr" "$(blocks "$part")"
  printf '%-5s installed %s, enabled %s, running pid %s, listening %s\n' "$part" "$ver" "$enabled" "$pid" "$addr"
}

consumer_part() { case $1 in wake-engine|router) return 0 ;; *) return 1 ;; esac; }

blocks() { case $1 in nats) echo "dapr, the stream and every live path" ;; wake-engine) echo "the wake read model fed by the bus" ;; router) echo "routing of the captain's replies" ;; dapr) echo "publishing through the sidecar" ;; *) echo "delivery to the captain" ;; esac; }

mkdir -p "$STATE/bus" || fail state "cannot create $STATE/bus" "everything"

# 1. The Go command. A host with no toolchain and no built binary cannot run any service.
"$BUS" status >/dev/null 2>"$STATE/bus/build.log" \
  || fail jg-bus "the Go command is not built and there is no Go toolchain (install go), see $STATE/bus/build.log" "every service"
printf 'jg-bus built, state %s\n' "$STATE/bus"

# 2. The pinned tools.
for t in nats-server nats daprd ntfy; do ensure_tool "$t"; done

sup=$(supervisor)
started=0
for part in nats wake-engine router dapr ntfy deliver; do
  if [ "$mode" = up ]; then
    if [ "$sup" = systemd ]; then
      changed=0; install_unit "$part" && changed=1
      name=$(unit_name "$part")
      [ "$changed" = 0 ] || systemctl --user daemon-reload || fail "$part" "systemctl daemon-reload failed" "its service"
      systemctl --user enable "$name" >/dev/null 2>&1 || fail "$part" "cannot enable $name" "$(blocks "$part")"
      # A consumer runs the built command, so a rebuilt one restarts it (its pid file is written at start).
      if consumer_part "$part" && [ "$changed" = 0 ] && [ "$STATE/bin/jg-bus" -nt "$STATE/bus/$part.pid" ]; then changed=1; fi
      if [ "$changed" = 1 ] && systemctl --user is-active --quiet "$name"; then
        systemctl --user restart "$name" || fail "$part" "cannot restart $name" "$(blocks "$part")"
      else
        systemctl --user start "$name" || fail "$part" "cannot start $name, see journalctl --user -u $name" "$(blocks "$part")"
      fi
    elif [ "$part" = nats ]; then
      "$BUS" ensure >/dev/null 2>&1
    elif [ "$started" = 0 ]; then
      "$BUS" serve >/dev/null 2>&1; started=1
    fi
  fi
  if consumer_part "$part"; then
    [ "$mode" = status ] || wait_consumer "$part" || true
  elif [ "$part" != deliver ]; then
    [ "$mode" = status ] || wait_listening "$(listen_addr "$part")" || true
  fi
  report "$part" "$sup"
  if [ "$part" = nats ]; then
    [ "$mode" = status ] || "$BUS" bootstrap >/dev/null 2>&1
    stream=$(sed -n 's/.*"name"[^"]*"\([^"]*\)".*/\1/p' "$ROOT/core/bus/stream.json" | head -n 1)
    "$BUS" stream >/dev/null 2>&1 \
      || fail stream "the $stream stream does not exist on the server, see $STATE/bus/stream.log" "every live path"
    echo "stream $stream exists"
  fi
done
echo "stack: up ($sup)"
