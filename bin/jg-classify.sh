#!/usr/bin/env bash
# jg-classify.sh - the status classifier's entry point: build the Go command once, then run it.
#
# The status-line tests and status-file scans (captain-relevance, declared waits, paused-until,
# the latest-event read) are owned by the Go command at core/classify/cmd/jg-classify, and its
# header is the one owner of that contract. bin/jg-classify-lib.sh keeps the function names the
# watcher, the daemon and the drain call and forwards each to this dispatcher; the shell reader
# those functions held is deleted, so this file adds no behaviour. The binary is built on first
# use inside the home's own state directory, never into the repository.
#
# CONTRACT.
#   binary  JG_CLASSIFY_BIN when set, else $STATE/bin/jg-classify. It is rebuilt when it is
#           missing or older than a source file, and the build lands under a temporary name so
#           a partial binary is never executed.
#   go      JG_CLASSIFY_GO when set, else `go` on PATH.
#   missing With neither a current binary nor a Go toolchain the dispatcher names what is
#           missing on stderr and exits 2, never 0 or 1, so a caller can tell a broken
#           classifier from a "no" answer.
#
# Usage: jg-classify.sh <command> [args] - see core/classify/cmd/jg-classify/main.go.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
SOURCE_DIR=$ROOT/core/classify
BIN=${JG_CLASSIFY_BIN:-$STATE/bin/jg-classify}
GO=${JG_CLASSIFY_GO:-go}

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
  if ! ( cd "$SOURCE_DIR" && "$GO" build -o "$tmp" ./cmd/jg-classify ) >&2; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0755 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$BIN"
}

if stale && ! build; then
  printf 'jg-classify: no runnable classifier at %s, and no Go toolchain to build one (set JG_CLASSIFY_GO, or install go): refusing to guess a classification\n' "$BIN" >&2
  exit 2
fi

exec "$BIN" "$@"
