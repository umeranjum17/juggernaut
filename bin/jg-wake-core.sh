#!/usr/bin/env bash
# jg-wake-core.sh - the wake library's entry point: build the Go command once, then run it.
#
# The queue read-model decisions - what makes two rows one row, the keys queued for a kind, which
# sequence numbers are still queued, how many rows an actor could act on, and whether a branch
# grant's row snapshot is well formed - and the urgency routing (the class now, batch or silent an
# event gets from the rule file, the re-alert dedupe and the hourly silence cap) are owned by the Go
# command at core/wake/cmd/jg-wake-core,
# and its header is the one owner of that contract. bin/jg-wake-lib.sh keeps the function names the
# watcher, the drain, the guard and the producers call and forwards each to this dispatcher; the
# shell readers those functions held are deleted, so this file adds no behaviour. The binary is
# built on first use into the user's cache, keyed by this checkout, never into the repository and
# never into a home: a reader such as jg-flow scans other homes and must leave every one of them
# byte for byte as it found it (core/fleet-flow/tests/jg-flow.test.sh asserts that).
#
# CONTRACT.
#   binary  JG_WAKE_CORE_BIN when set, else
#           ${XDG_CACHE_HOME:-$HOME/.cache}/jg-wake-core/<checkout-key>/jg-wake-core, beside
#           jg-classify's cache and outside every Juggernaut home. It is rebuilt when it is
#           missing or older than a source file, and the build lands under a temporary name so a
#           partial binary is never executed.
#   go      JG_WAKE_CORE_GO when set, else `go` on PATH.
#   missing With neither a current binary nor a Go toolchain the dispatcher names what is missing
#           on stderr and exits 2, never 0 or 1, so a caller can tell a broken reader from an
#           empty queue.
#
# Usage: jg-wake-core.sh [flags] <command> [args] - see core/wake/cmd/jg-wake-core/main.go.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
SOURCE_DIR=$ROOT/core/wake
CACHE=${XDG_CACHE_HOME:-${HOME:-$STATE}/.cache}/jg-wake-core
# One binary per checkout: sibling worktrees share the cache, and a binary built from another
# checkout's sources must never answer this one's call.
CACHE_KEY=$(printf '%s\n' "$ROOT" | cksum | cut -d' ' -f1)
BIN=${JG_WAKE_CORE_BIN:-$CACHE/$CACHE_KEY/jg-wake-core}
GO=${JG_WAKE_CORE_GO:-go}

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
  if ! ( cd "$SOURCE_DIR" && "$GO" build -o "$tmp" ./cmd/jg-wake-core ) >&2; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0755 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$BIN"
}

if stale && ! build; then
  printf 'jg-wake-core: no runnable wake core at %s, and no Go toolchain to build one (set JG_WAKE_CORE_GO, or install go): refusing to guess what the wake queue holds or what class an event has\n' "$BIN" >&2
  exit 2
fi

exec "$BIN" "$@"
