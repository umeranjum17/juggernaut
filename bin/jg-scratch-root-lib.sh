#!/usr/bin/env bash
# jg-scratch-root-lib.sh - the one disk scratch root for heavy temp writers. Sourced; it defines functions only.
# /tmp is RAM on this host (tmpfs), so a writer of bulk scratch (test shards and fixtures, browser profiles, yarn,
# kotlin and android dirs) puts it on disk under the cache home instead: ${JG_SCRATCH_ROOT:-<cache home>/jg-scratch,
# where the cache home is $XDG_CACHE_HOME or $HOME/.cache}. bin/jg-reaper-lib.sh already reaps stale processes under it
# and bin/jg-tmp-sweep.sh sweeps it with --root. Only /tmp itself is not changed here (that needs a mount change).
#   jg_scratch_root        print the root, created mode 0700; non-zero (and nothing printed) when it cannot be made
#   jg_scratch_pin_tmpdir  export TMPDIR=<root> unless the caller already set a TMPDIR that is not /tmp or /var/tmp, so
#                          every mktemp "${TMPDIR:-/tmp}/..." under the caller and its children lands on disk; a
#                          root that cannot be made leaves TMPDIR as it was
jg_scratch_root() {
  local root=${JG_SCRATCH_ROOT:-${XDG_CACHE_HOME:-${HOME:-}/.cache}/jg-scratch}
  case $root in /*) ;; *) return 1 ;; esac
  mkdir -p "$root" 2>/dev/null && chmod 0700 "$root" 2>/dev/null || return 1
  printf '%s\n' "$root"
}

jg_scratch_pin_tmpdir() {
  local root
  case ${TMPDIR:-} in ''|/tmp|/tmp/|/var/tmp|/var/tmp/) ;; *) return 0 ;; esac
  root=$(jg_scratch_root) || return 0
  export TMPDIR=$root
}
