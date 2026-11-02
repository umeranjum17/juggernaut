#!/usr/bin/env bash
# jg-watch-core.sh - the watcher's window inventory: build the Go command once, then run it.
#
# The inventory rules (which record is watched, which window a record names, and the kind,
# backend and harness a window answers) are owned by the Go command at
# core/watch/cmd/jg-watch-core, and that file's header is the one owner of them. Its
# documentation, with the replay against the shell those rules replaced and that replay's
# control run, is core/watch/README.md. bin/jg-watch.sh reads one inventory per cycle and
# its window accessors answer from it; the shell reader this port deleted re-walked every
# record for every answer, forking grep and cut each time. This file adds no behaviour.
#
# CONTRACT.
#   binary  JG_WATCH_CORE_BIN when set, else
#           ${XDG_CACHE_HOME:-$HOME/.cache}/jg-watch-core/<checkout-key>/jg-watch-core,
#           beside jg-classify's cache and outside every Juggernaut home: a reader such as
#           bin/jg-flow.sh scans other homes and must leave each one byte for byte as it
#           found it. It is rebuilt when it is missing or older than a source file, and the
#           build lands under a temporary name so a partial binary is never executed.
#   go      JG_WATCH_CORE_GO when set, else `go` on PATH.
#   missing With neither a current binary nor a Go toolchain this dispatcher names what is
#           missing on stderr and exits 2, never 0, so the watcher can tell a broken
#           inventory from an empty fleet instead of supervising blind.
#
# Usage: jg-watch-core.sh <command> [args] - see core/watch/cmd/jg-watch-core/main.go.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
SOURCE_DIR=$ROOT/core/watch
CACHE=${XDG_CACHE_HOME:-${HOME:-$STATE}/.cache}/jg-watch-core
# One binary per checkout: sibling worktrees share the cache, and a binary built from
# another checkout's sources must never answer this one's call.
CACHE_KEY=$(printf '%s\n' "$ROOT" | cksum | cut -d' ' -f1)
BIN=${JG_WATCH_CORE_BIN:-$CACHE/$CACHE_KEY/jg-watch-core}
GO=${JG_WATCH_CORE_GO:-go}

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
  if ! ( cd "$SOURCE_DIR" && "$GO" build -o "$tmp" ./cmd/jg-watch-core ) >&2; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0755 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$BIN"
}

if stale && ! build; then
  printf 'jg-watch-core: no runnable window inventory at %s, and no Go toolchain to build one (set JG_WATCH_CORE_GO, or install go): refusing to report a fleet it cannot read\n' "$BIN" >&2
  exit 2
fi

exec "$BIN" "$@"
