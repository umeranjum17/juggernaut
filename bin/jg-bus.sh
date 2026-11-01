#!/usr/bin/env bash
# jg-bus.sh - the captain channel's entry point: build the Go command once, then run it.
#
# The channel's shape - the modes, the record, the publish, the delivery, the reply
# router, the parity replay and the three services - is owned by the Go command at
# core/bus/cmd/jg-bus, and its header is the one owner of that contract. This file is
# only the dispatcher, so a home needs nothing but a checkout and a Go toolchain: the
# binary is built on first use inside the home's own state directory, never into the
# repository. The stack decision that new long-running parts are Go is why the
# shell that held this logic is deleted and this dispatcher adds no behaviour.
#
# CONTRACT.
#   binary  JG_BUS_BIN when set, else $STATE/bin/jg-bus. It is rebuilt when it is
#           missing or older than a source file, so a checkout that moved is never run
#           as a stale binary, and the build lands under a temporary name so a partial
#           binary is never executed.
#   go      JG_BUS_GO when set, else `go` on PATH.
#   missing When neither a current binary nor a Go toolchain is available, `publish`
#           still exits 0, because a captain-facing emitter is never broken by the tee,
#           and every other command exits 2 after naming what is missing.
#
# Usage: jg-bus.sh <command> ... (the command's own header owns each command).
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
SOURCE_DIR=$ROOT/core/bus
BIN=${JG_BUS_BIN:-$STATE/bin/jg-bus}
GO=${JG_BUS_GO:-go}

# The command resolves the rest of its paths from this checkout, which is how a binary
# living in the state directory still reads the repository's defaults.
export JG_BUS_ROOT=$ROOT

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

if stale && ! build; then
  printf 'jg-bus: no runnable command at %s, and no Go toolchain to build one (set JG_BUS_GO, or install go)\n' "$BIN" >&2
  if [ "${1:-}" = publish ]; then
    exit 0
  fi
  exit 2
fi

exec "$BIN" "$@"
