#!/usr/bin/env bash
# jg-teardown-core.sh - the teardown decisions' entry point: build the Go command once, then run it.
#
# The landed-work test - "has this worktree's work landed?", the forge proof and the
# default-branch content check teardown must pass before it discards a worktree - is owned by the
# Go command at core/teardown/cmd/jg-teardown, and its header is the one owner of that contract.
# bin/jg-teardown.sh gathers the task's recorded facts and calls this dispatcher; the shell test
# it held is deleted, so this file adds no behaviour. The binary is built on first use inside the
# home's own state directory, never into the repository.
#
# CONTRACT.
#   binary  JG_TEARDOWN_CORE_BIN when set, else $STATE/bin/jg-teardown-core. It is rebuilt when
#           it is missing or older than a source file, and the build lands under a temporary
#           name so a partial binary is never executed.
#   go      JG_TEARDOWN_CORE_GO when set, else `go` on PATH.
#   missing With neither a current binary nor a Go toolchain the dispatcher names what is
#           missing on stderr and exits 2, never 0, so a caller cannot read a broken check as
#           "landed" and teardown refuses rather than discarding unproved work.
#
# Usage: jg-teardown-core.sh <command> [args] - see core/teardown/cmd/jg-teardown/main.go.
set -u

# The sources live where this file really is: a copy of bin/ made of symlinks (as the teardown
# suite and a relocated home make) still builds from the checkout the links point into.
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
SOURCE_DIR=$ROOT/core/teardown
BIN=${JG_TEARDOWN_CORE_BIN:-$STATE/bin/jg-teardown-core}
GO=${JG_TEARDOWN_CORE_GO:-go}

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
  if ! ( cd "$SOURCE_DIR" && "$GO" build -o "$tmp" ./cmd/jg-teardown ) >&2; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0755 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$BIN"
}

if stale && ! build; then
  printf 'jg-teardown-core: no runnable landed-work check at %s, and no Go toolchain to build one (set JG_TEARDOWN_CORE_GO, or install go): refusing rather than treating the work as landed\n' "$BIN" >&2
  exit 2
fi

exec "$BIN" "$@"
