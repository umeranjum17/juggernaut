#!/usr/bin/env bash
# jg-spawn-core.sh - the spawn decision core's entry point: build the Go command once, then run it.
#
# The launch flags a harness receives (--model, the effort mapping per harness) and the checks
# that keep a ship brief and the spawn's own flags in agreement (branch, mode, upstream consent,
# forge, yolo on gerrit, and the two lower-rigor notices) are owned by the Go command at
# core/spawn/cmd/jg-spawn-core, and its header is the one owner of that contract. bin/jg-spawn.sh
# calls this dispatcher where it used to hold those shell bodies; they are deleted, so this file
# adds no behaviour. The binary is built on first use inside the home's own state directory,
# never into the repository.
#
# CONTRACT.
#   binary  JG_SPAWN_CORE_BIN when set, else $STATE/bin/jg-spawn-core. It is rebuilt when it is
#           missing or older than a source file, and the build lands under a temporary name so
#           a partial binary is never executed.
#   go      JG_SPAWN_CORE_GO when set, else `go` on PATH.
#   missing With neither a current binary nor a Go toolchain the dispatcher names what is
#           missing on stderr and exits 2, never 0 or 1, so a caller can tell a broken
#           core from an answer; a spawn that gets 2 stops rather than guess a launch flag.
#
# Usage: jg-spawn-core.sh <command> [args] - see core/spawn/cmd/jg-spawn-core/main.go.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
SOURCE_DIR=$ROOT/core/spawn
BIN=${JG_SPAWN_CORE_BIN:-$STATE/bin/jg-spawn-core}
GO=${JG_SPAWN_CORE_GO:-go}

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
  if ! ( cd "$SOURCE_DIR" && "$GO" build -o "$tmp" ./cmd/jg-spawn-core ) >&2; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0755 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$BIN"
}

if stale && ! build; then
  printf 'jg-spawn-core: no runnable spawn core at %s, and no Go toolchain to build one (set JG_SPAWN_CORE_GO, or install go): refusing to guess a launch decision\n' "$BIN" >&2
  exit 2
fi

exec "$BIN" "$@"
