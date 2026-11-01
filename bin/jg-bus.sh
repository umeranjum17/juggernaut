#!/usr/bin/env bash
# jg-bus.sh - the captain channel's entry point: the Go command for the event path,
# and the shell service path until its own slice lands.
#
# The channel's shape - the modes, the record, the publish, the delivery, the reply
# router, the parity replay and the three services - is owned by the Go command at
# core/bus/cmd/jg-bus, and its header is the one owner of that contract. This file is
# the dispatcher, so a home needs nothing but a checkout and a Go toolchain: the binary
# is built on first use inside the home's own state directory, never into the
# repository. The stack decision is that new long-running parts are Go, so the logic
# moves out of this file slice by slice.
#
# CONTRACT.
#   go       config, publish, parity, reply, status and unit are the Go command's. It is
#            built here when JG_BUS_BIN is unset, and it is rebuilt when it is missing
#            or older than a source file, so a checkout that moved is never run as a
#            stale binary; the build lands under a temporary name so a partial binary is
#            never executed.
#   shell    serve, ensure, stop and bootstrap still run below, unchanged from the
#            command this file used to be, until the service slice ports them.
#   missing  When neither a current binary nor a Go toolchain is available, `publish`
#            still exits 0, because a captain-facing emitter is never broken by the tee,
#            and every other ported command exits 2 after naming what is missing.
#
# Usage: jg-bus.sh <command> ... (the command's own header owns each command).
set -u
export LC_ALL=C

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
RUNTIME=$STATE/bus
SOURCE_DIR=$ROOT/core/bus
BIN=${JG_BUS_BIN:-$STATE/bin/jg-bus}
GO=${JG_BUS_GO:-go}
# The command resolves the rest of its paths from this checkout, which is how a binary
# living in the state directory still reads the repository's defaults.
export JG_BUS_ROOT=$ROOT

die() { printf 'jg-bus: %s\n' "$*" >&2; exit 2; }
say() { printf '%s\n' "$*" >&2; }

# stale: 0 when the binary is absent or older than any source file.
stale() {
  [ -x "$BIN" ] || return 0
  [ -z "$(find "$SOURCE_DIR" -name '*.go' -newer "$BIN" -print -quit 2>/dev/null)" ] || return 0
  return 1
}

# build: compile the command into place.
build() {
  local tmp
  command -v "$GO" >/dev/null 2>&1 || return 1
  mkdir -p "${BIN%/*}" || return 1
  tmp="$BIN.tmp.$$"
  if ! ( cd "$SOURCE_DIR" && "$GO" build -o "$tmp" ./cmd/jg-bus ) >&2; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0755 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$BIN"
}

# go_command: 0 when this command is the Go command's.
go_command() {
  case "${1:-status}" in
    config|publish|reply|parity|status|unit) return 0 ;;
  esac
  return 1
}

if go_command "${1:-status}"; then
  if stale && ! build; then
    printf 'jg-bus: no runnable command at %s, and no Go toolchain to build one (set JG_BUS_GO, or install go)\n' "$BIN" >&2
    if [ "${1:-}" = publish ]; then
      exit 0
    fi
    exit 2
  fi
  exec "$BIN" "$@"
fi

# --- the service path, still shell in this slice ----------------------------
# The three services, the stream they carry and the pid files they own are ported
# next; until then the commands below run unchanged, so a home loses nothing while
# the port is in two slices.

bus_file() {  # <path under core/bus> -> prints the file in force
  if [ -f "$JG_HOME/config/bus/$1" ]; then printf '%s' "$JG_HOME/config/bus/$1"
  else printf '%s' "$ROOT/core/bus/$1"; fi
}

# The channel config files, most specific first.

CHANNEL_FILES=("${JG_CAPTAIN_CHANNEL:-}" "$JG_HOME/config/captain-channel" "$ROOT/defaults/captain-channel")

# One key out of one config file, or nothing.
file_get() {  # <file> <key>
  [ -n "${1-}" ] && [ -f "$1" ] || return 0
  awk -v k="$2" '$1 == "set" && $2 == k { sub(/^[[:space:]]*set[[:space:]]+[^[:space:]]+[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$1"
}

# One key from the channel config, first file that carries it wins.
cfg() {  # <key>
  local key=$1 file v
  for file in "${CHANNEL_FILES[@]}"; do
    v=$(file_get "$file" "$key")
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 1
}

start_one() {  # <name> <command...>; CWD is the runtime dir
  local name=$1 pid
  shift
  [ -f "$RUNTIME/$name.pid" ] && kill -0 "$(cat "$RUNTIME/$name.pid")" 2>/dev/null && { say "$name: already running"; return 0; }
  "$@" >"$RUNTIME/$name.log" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >"$RUNTIME/$name.pid"
  say "$name: started ($pid), log $RUNTIME/$name.log"
}

# The JetStream stream, from its file. Needs the nats client; without it the
# event record still holds every event, so this is a reported skip, not a stop.
stream_name() {
  sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/core/bus/stream.json" | head -1
}

# Create the stream from its file when it is not there; 0 when it is present.
ensure_stream() {
  local conf=$ROOT/core/bus/stream.json name
  name=$(stream_name)
  command -v nats >/dev/null 2>&1 || return 1
  nats -s "$(cfg nats-url)" stream info "$name" >/dev/null 2>&1 && return 0
  nats -s "$(cfg nats-url)" stream add --config "$conf" >"$RUNTIME/stream.log" 2>&1
}

# Is anything listening on the configured address? The redirection lives in a
# subshell so a refused port is only a status and nothing is applied to this shell.
bus_listening() {  # <nats-url>
  local hostport=${1#*://}
  ( : >"/dev/tcp/${hostport%%:*}/${hostport##*:}" ) 2>/dev/null
}

# wait_port: the same probe in a bounded loop, and the reason this file has no
# `exec` redirection: one here silenced every later line the script printed.
wait_port() {  # <host> <port>
  local tries=0
  while [ "$tries" -lt 100 ]; do
    if ( : >"/dev/tcp/$1/$2" ) 2>/dev/null; then return 0; fi
    sleep 0.1
    tries=$((tries + 1))
  done
  return 1
}

cmd_bootstrap() {
  local name
  name=$(stream_name)
  if ! command -v nats >/dev/null 2>&1; then
    say "stream: not created, no nats client on PATH (the event record still holds every event)"
    return 0
  fi
  if ensure_stream; then say "stream: $name ready"; else say "stream: $name not created, see $RUNTIME/stream.log"; fi
}

# ensure: what a bootstrap step runs. Start the server when it is not listening,
# create the stream when it is missing, and print one line either way. Idempotent,
# and it starts nothing but the server - the sidecar and ntfy stay opt-in.
cmd_ensure() {
  local nats_url hostport
  nats_url=$(cfg nats-url)
  hostport=${nats_url#*://}
  mkdir -p "$RUNTIME" || die "cannot create $RUNTIME"
  if ! command -v nats-server >/dev/null 2>&1; then
    say "bus: down, no nats-server on PATH"
    return 0
  fi
  if ! bus_listening "$nats_url"; then
    ( cd "$RUNTIME" && start_one nats nats-server -c "$(bus_file nats.conf)" ) >/dev/null 2>&1
    if ! wait_port "${hostport%%:*}" "${hostport##*:}"; then
      say "bus: down, the server did not listen on $nats_url; see $RUNTIME/nats.log"
      return 0
    fi
  fi
  if ensure_stream; then
    say "bus: up $nats_url stream $(stream_name)"
  else
    say "bus: up $nats_url, stream $(stream_name) missing (no nats client, or the server refused; see $RUNTIME/stream.log)"
  fi
}

cmd_serve() {
  local nats_url hostport
  mkdir -p "$RUNTIME" || die "cannot create $RUNTIME"
  nats_url=$(cfg nats-url)
  hostport=${nats_url#*://}
  cd "$RUNTIME" || die "cannot enter $RUNTIME"
  if command -v nats-server >/dev/null 2>&1; then
    start_one nats nats-server -c "$(bus_file nats.conf)"
    if wait_port "${hostport%%:*}" "${hostport##*:}"; then
      say "nats: listening on $nats_url"
      cmd_bootstrap
    else
      say "nats: did not start; see $RUNTIME/nats.log"
    fi
  else
    say "nats: not started, no nats-server on PATH"
  fi
  if command -v daprd >/dev/null 2>&1; then
    local components
    components=$(dirname "$(bus_file dapr/components/pubsub.yaml)")
    start_one dapr daprd --app-id "$(cfg dapr-app-id)" --dapr-http-port "$(cfg dapr-http-port)" \
      --dapr-grpc-port "$(cfg dapr-grpc-port)" --enable-metrics=false \
      --resources-path "$components"
  else
    say "dapr: not started, no daprd on PATH"
  fi
  if command -v ntfy >/dev/null 2>&1; then
    start_one ntfy ntfy serve -c "$(bus_file ntfy.yml)"
  else
    say "ntfy: not started, no ntfy on PATH"
  fi
  return 0
}

cmd_stop() {
  local name pid
  for name in nats dapr ntfy; do
    [ -f "$RUNTIME/$name.pid" ] || continue
    pid=$(cat "$RUNTIME/$name.pid")
    kill "$pid" 2>/dev/null && say "$name: stopped"
    rm -f "$RUNTIME/$name.pid"
  done
  return 0
}

case "${1:-status}" in
  serve) shift; cmd_serve "$@" ;;
  ensure) shift; cmd_ensure "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  bootstrap) shift; mkdir -p "$RUNTIME" && cd "$RUNTIME" && cmd_bootstrap "$@" ;;
  *) printf 'jg-bus: unknown command: %s\n' "${1:-}" >&2; exit 2 ;;
esac
