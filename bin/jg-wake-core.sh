#!/usr/bin/env bash
# jg-wake-core.sh - the wake library's Go decisions: build the Go command once, then run it.
#
# Wake urgency routing - the class (now, batch or silent) every event gets from the rule file, the
# re-alert dedupe and the hourly silence cap - is owned by the Go command at
# core/wake/cmd/jg-wake-core, and its header is the one owner of that contract.
# bin/jg-wake-lib.sh resolves the home and calls this dispatcher; the shell rule reader it held is
# deleted, so this file adds no behaviour. The binary is built on first use inside the home's own
# state directory, never into the repository.
#
# CONTRACT.
#   binary  JG_WAKE_CORE_BIN when set, else $STATE/bin/jg-wake-core. It is rebuilt when it is
#           missing or older than a source file, and the build lands under a temporary name so a
#           partial binary is never executed.
#   go      JG_WAKE_CORE_GO when set, else `go` on PATH.
#   missing With neither a current binary nor a Go toolchain the dispatcher names what is missing
#           on stderr and exits 2. The wake library then answers `now` for the event, the class
#           that wakes a model: an unjudged event is delivered, never hidden.
#
# Usage: jg-wake-core.sh [flags] <command> [args] - see core/wake/cmd/jg-wake-core/main.go.
set -u

# The sources live where this file really is: a copy of bin/ made of symlinks still builds from
# the checkout the links point into.
SELF=${BASH_SOURCE[0]}
while [ -L "$SELF" ]; do
  d=$(cd "$(dirname "$SELF")" && pwd) || exit 2
  SELF=$(readlink "$SELF")
  case "$SELF" in /*) ;; *) SELF=$d/$SELF ;; esac
done
SCRIPT_DIR="$(d=${SELF%/*}; [ "$d" != "$SELF" ] || d=.; cd "${d:-/}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
SOURCE_DIR=$ROOT/core/wake
BIN=${JG_WAKE_CORE_BIN:-$STATE/bin/jg-wake-core}
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
  [ -d "$SOURCE_DIR" ] || return 1
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
  printf 'jg-wake-core: no runnable wake router at %s, and no Go toolchain or core/wake sources to build one (set JG_WAKE_CORE_GO, or install go): treating the event as urgent rather than hiding it\n' "$BIN" >&2
  exit 2
fi

exec "$BIN" "$@"
