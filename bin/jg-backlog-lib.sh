# shellcheck shell=bash
# Backlog store access for every script that reads or writes this home's backlog.
# Usage: . bin/jg-backlog-lib.sh
#
# The backlog is this home's Beads store, named by the absolute BEADS_DIR in
# `config/beads-dir`. jg_backlog_beads_read owns every read, jg_backlog_beads_write owns
# add, update, done, block, unblock, start, reopen, hold, unhold, relink and the
# stage, take and drop a handoff moves rows with, and bin/jg-backlog.sh serves those
# verbs and refuses every other one. There is no other backend and no fallback: a
# home with no store named reports that, and its caller stops.

# Reads through bin/jg-beads.sh, the only way bd runs; bin/jg-beads-view.py owns the
# field mapping. bd's stderr carries routine warnings, so it surfaces only on failure.
# The store path is never derived, because a store inside a home's git clone is refused.
jg_backlog_beads_store() {  # <config_dir>: prints the BEADS_DIR, or refuses.
  local store
  store=$(tr -d '[:space:]' < "$1/beads-dir" 2>/dev/null) || store=
  if [ -z "$store" ]; then
    printf 'jg-backlog: the beads backlog needs its store: put an absolute BEADS_DIR in %s/beads-dir\n' "$1" >&2
    return 2
  fi
  printf '%s\n' "$store"
}

# The backlog as markdown lines, rendered from the store.
jg_backlog_text() {  # <config_dir> [<backlog_file>]
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

# Beads answers ready and blocked, so the read asks bd for them before it lists the rows:
# `bd ready` first, because that call wakes a dated hold whose day has come and the listing must show it awake.
# A list asks `bd blocked` only when it shows blocked rows or the blocked fields, because the call costs about 0.3 s.
jg_backlog_beads_read() {  # <config_dir> <show|view|list|ready|markdown|links> [args...]
  local bin_dir store err rows rc=0 scratch word repo="" want_ready="" want_blocked=""
  store=$(jg_backlog_beads_store "$1") || return 2
  shift
  bin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  case "${1:-}" in
    ready) want_ready=1 ;;
    show|view) want_blocked=1 ;;
    list) case " $* " in *blocked*) want_blocked=1 ;; esac ;;
  esac
  scratch=$(mktemp -d) || return 2
  err=$scratch/err
  if [ -n "$want_ready" ]; then
    for word in "${@:2}"; do
      case "$word" in --repo=*) repo=${word#--repo=} ;; --repo) repo=- ;; *) [ "$repo" = - ] && repo=$word ;; esac
    done
    [ "$repo" = - ] && repo=""
    BEADS_DIR=$store "$bin_dir/jg-beads.sh" ready --limit 0 --json ${repo:+--label "project:$repo"} >"$scratch/ready" 2>"$err" || rc=$?
  fi
  if [ "$rc" -eq 0 ] && [ -n "$want_blocked" ]; then
    BEADS_DIR=$store "$bin_dir/jg-beads.sh" blocked --json >"$scratch/blocked" 2>"$err" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    rows=$(BEADS_DIR=$store "$bin_dir/jg-beads.sh" list --all --limit 0 --json 2>>"$err") || rc=$?
  fi
  [ "$rc" -eq 0 ] || cat -- "$err" >&2
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$rows" | JG_BEADS_READY=${want_ready:+$scratch/ready} JG_BEADS_BLOCKED=${want_blocked:+$scratch/blocked} \
      python3 "$bin_dir/jg-beads-view.py" "$@" || rc=$?
  fi
  rm -f -- "$scratch/ready" "$scratch/blocked" "$scratch/err"
  rmdir -- "$scratch"
  return "$rc"
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
