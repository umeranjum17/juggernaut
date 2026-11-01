#!/usr/bin/env bash
# jg-guard-host.sh - the guard host's entry point: build the Go command once, then run it.
#
# The guard host's shape - the Rego rule decision, the delete rule, and repo-guard's shim
# and pre-push modes - is owned by the Go command at core/guard-host/cmd/jg-guard-host, and
# its header is the one owner of that contract. This file is only the dispatcher, so a home
# needs nothing but a checkout and a Go toolchain: the binary is built on first use inside
# the home's own state directory, never into the repository. These decisions are Go by the
# fleet's stack decision, so the shell and JavaScript that held them are deleted and this
# dispatcher adds no behaviour.
#
# CONTRACT.
#   binary  JG_GUARD_HOST_BIN when set, else $STATE/bin/jg-guard-host. It is rebuilt when
#           it is missing or older than a source file, so a checkout that moved is never run
#           as a stale binary, and the build lands under a temporary name so a partial
#           binary is never executed.
#   go      JG_GUARD_HOST_GO when set, else `go` on PATH.
#   root    JG_GUARD_HOST_ROOT when set, else this checkout, so the command reads
#           policy/guard from the checkout that dispatched it.
#   missing A guard that cannot run never silently allows the command it was asked about:
#           with neither a current binary nor a Go toolchain, the dispatcher names what is
#           missing on stderr and exits 2, which is the blocking answer every hook reads.
#
# Usage: jg-guard-host.sh hook | --list | delete [--runtime <name>] | decide <command> |
#        gh <args...> | gh-axi <args...> | pre-push <remote> <url>
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
SOURCE_DIR=$ROOT/core/guard-host
BIN=${JG_GUARD_HOST_BIN:-$STATE/bin/jg-guard-host}
GO=${JG_GUARD_HOST_GO:-go}

# The command resolves its rules from this checkout, which is how a binary living in the
# state directory still reads the repository's policy.
export JG_GUARD_HOST_ROOT=${JG_GUARD_HOST_ROOT:-$ROOT}

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
  if ! ( cd "$SOURCE_DIR" && "$GO" build -o "$tmp" ./cmd/jg-guard-host ) >&2; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0755 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$BIN"
}

if stale && ! build; then
  printf 'jg-guard-host: no runnable guard at %s, and no Go toolchain to build one (set JG_GUARD_HOST_GO, or install go): refusing rather than allowing an unjudged command\n' "$BIN" >&2
  exit 2
fi

exec "$BIN" "$@"
