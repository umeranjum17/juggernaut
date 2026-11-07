# shellcheck shell=bash
# Backlog store access for every script that reads or writes this home's backlog.
# Usage: . bin/jg-tasks-axi-lib.sh
#
# The backlog is this home's Beads store, named by the absolute BEADS_DIR in
# `config/beads-dir`. jg_backlog_beads_read owns every read, jg_backlog_beads_write owns
# add, update, done, block, unblock, start, reopen, hold, unhold, relink and the
# stage, take and drop a handoff moves rows with, and bin/jg-tasks-axi.sh refuses
# every other verb. There is no other backend and no fallback: a home with no store
# named reports that, and its caller stops.

# Reads through bin/jg-beads.sh, the only way bd runs; bin/jg-beads-view.py owns the
# field mapping. bd's stderr carries routine warnings, so it surfaces only on failure.
# The store path is never derived, because a store inside a home's git clone is refused.
jg_backlog_beads_store() {  # <config_dir>: prints the BEADS_DIR, or refuses.
  local store
  store=
  [ -r "$1/beads-dir" ] && store=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e q < "$1/beads-dir")
  if [ -z "$store" ]; then
    printf 'jg-tasks-axi: the beads backlog needs its store: put an absolute BEADS_DIR in %s/beads-dir\n' "$1" >&2
    return 2
  fi
  printf '%s\n' "$store"
}

# The backlog as markdown lines, rendered from the store.
jg_backlog_text() {  # <config_dir>
  jg_backlog_beads_read "$1" markdown
}

# The start checks' one line on this home's store: the summary of `jg-beads.sh check`, or why it failed.
jg_backlog_beads_health() {  # <config_dir>
  local bin_dir store out rc=0
  store=$(jg_backlog_beads_store "$1" 2>&1) || { printf '%s\n' "$store"; return 2; }
  bin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  out=$(BEADS_DIR=$store "$bin_dir/jg-beads.sh" check 2>&1) || rc=$?
  printf '%s\n' "${out##*$'\n'}"
  return "$rc"
}

jg_backlog_beads_write() {  # <config_dir> <a verb of bin/jg-beads-write.py> [args...]
  local bin_dir store
  store=$(jg_backlog_beads_store "$1") || return 2
  shift
  bin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  BEADS_DIR=$store python3 "$bin_dir/jg-beads-write.py" "$@"
}

jg_backlog_beads_read() {  # <config_dir> <show|view|list|ready|markdown|links> [args...]
  local bin_dir store err rows rc=0
  store=$(jg_backlog_beads_store "$1") || return 2
  shift
  bin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  err=$(mktemp) || return 2
  rows=$(BEADS_DIR=$store "$bin_dir/jg-beads.sh" list --all --limit 0 --json 2>"$err") || rc=$?
  [ "$rc" -eq 0 ] || cat -- "$err" >&2
  rm -f -- "$err"
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$rows" | python3 "$bin_dir/jg-beads-view.py" "$@"
}

# One verb, read or write, for bin/jg-backlog-transition-lib.sh's row calls.
jg_backlog_beads_serve() {  # <config_dir> <verb> [args...]
  case "${2:-}" in
    show|view|list|ready|links)
      local config=$1
      shift
      jg_backlog_beads_read "$config" "$@"
      ;;
    *) jg_backlog_beads_write "$@" ;;
  esac
}
