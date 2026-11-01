#!/usr/bin/env bash
# jg-herdr.sh - the herdr backend core's entry point: build the Go command once, then run it.
#
# The decisions and answer readers of the herdr adapter (the release-floor verdict, the
# presentation preference, agent names, and every read of a `herdr` JSON answer that bin/backends/herdr.sh
# once did with jq) are owned by the Go command at core/herdr/cmd/jg-herdr, and its header is
# the one owner of that contract. bin/backends/herdr.sh keeps the function names its callers use
# and forwards each to this dispatcher, so this file adds no behaviour. The binary is built on
# first use inside the home's own state directory, never into the repository.
#
# CONTRACT.
#   binary  JG_HERDR_BIN when set, else $STATE/bin/jg-herdr. It is rebuilt when it is missing
#           or older than a source file, and the build lands under a temporary name so a
#           partial binary is never executed.
#   go      JG_HERDR_GO when set, else `go` on PATH.
#   missing With neither a current binary nor a Go toolchain the dispatcher names what is
#           missing on stderr and exits 2, with nothing on stdout, so a caller never reads a
#           broken core as an empty herdr answer.
#
# Usage: jg-herdr.sh <command> [args] - see core/herdr/cmd/jg-herdr/main.go.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
SOURCE_DIR=$ROOT/core/herdr
BIN=${JG_HERDR_BIN:-$STATE/bin/jg-herdr}
GO=${JG_HERDR_GO:-go}

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
  if ! ( cd "$SOURCE_DIR" && "$GO" build -o "$tmp" ./cmd/jg-herdr ) >&2; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0755 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$BIN"
}

if stale && ! build; then
  printf 'jg-herdr: no runnable herdr core at %s, and no Go toolchain to build one (set JG_HERDR_GO, or install go): refusing to guess a herdr answer\n' "$BIN" >&2
  exit 2
fi

exec "$BIN" "$@"
