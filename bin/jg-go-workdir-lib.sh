#!/usr/bin/env bash
# jg-go-workdir-lib.sh - the single owner of preparing GOTMPDIR before a dispatcher's build.
#
# Sourced, never executed. bin/jg-spawn.sh exports a task's GOTMPDIR under /tmp/jg-<task-id>
# and creates it at spawn, but a long-lived session (a Squad Lead) can outlive that folder: a
# reboot or a /tmp cleanup removes it while the exported path stays. `go build` then fails
# with "creating work dir", so a dispatcher whose binary went stale could never rebuild it.
#
#   jg_go_workdir_ready <caller-name>
#       With GOTMPDIR unset, does nothing. Otherwise creates it (mode 0700) when it is
#       missing, and refuses a symlink, a non-directory, or a directory another user owns.
#       Returns 1 after naming the problem on stderr, prefixed with <caller-name>.

jg_go_workdir_ready() { # <caller-name>
  [ -n "${GOTMPDIR:-}" ] || return 0
  if [ -L "$GOTMPDIR" ] || { [ -e "$GOTMPDIR" ] && { [ ! -d "$GOTMPDIR" ] || [ ! -O "$GOTMPDIR" ]; }; }; then
    printf '%s: unsafe Go work directory %s (must be a directory owned by the caller, not a symlink)\n' "$1" "$GOTMPDIR" >&2
    return 1
  fi
  if ! (umask 077; mkdir -p -- "$GOTMPDIR") || [ -L "$GOTMPDIR" ] || [ ! -O "$GOTMPDIR" ] || ! chmod 700 -- "$GOTMPDIR"; then
    printf '%s: cannot create or secure Go work directory %s\n' "$1" "$GOTMPDIR" >&2
    return 1
  fi
}
