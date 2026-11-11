# shellcheck shell=bash
# Fused backlog transitions for the scripts that own a task's physical record.
# Usage: . bin/jg-backlog-lib.sh; . bin/jg-backlog-transition-lib.sh
# (this library reads that one's Beads store helpers and never sources it itself).
#
# INVARIANT. In ordinary successful lifecycle state, `state/<id>.meta` exists
# <=> this home's backlog row for <id> is In flight; the one teardown crash
# window is represented by `state/<id>.backlog-close`. The script performing the
# mechanical record change owns the paired backlog transition and runs it in the
# same process, under the per-task meta lock it already holds, before it reports
# success. Nothing else - not a later agent turn, not a printed reminder - is
# load-bearing for the pairing.
#   bin/jg-spawn.sh      meta published => backlog `start`
#   bin/jg-teardown.sh   meta removed => backlog `done`, or `reopen`
#                        with the deliverable recorded when the row is still an
#                        open captain call (bin/jg-captain-hold.sh `open`), so
#                        cleanup never retires the captain's own question
#   bin/jg-bootstrap.sh  replays whatever a crash left behind, THIS HOME ONLY.
# bin/jg-fleet-snapshot.sh's classifier and bin/jg-squad-lead-reconcile.sh's
# cross-home nudge stay defense in depth, not the primary mechanism.
#
# SCOPE. jg_backlog_transition_applies is the single gate. It excludes
# squad_leads (persistent agents are never backlog items, the fleet-records skill).
# An unresolvable configured data directory or an unusable Beads store returns 2
# so callers refuse before mutation.
#
# ADDRESSING. Every row read and mutation runs the Beads provider against the
# store config/beads-dir names. Only the data directory is authorized, because it
# keeps no backlog file. Each write checks the status it read, so a row that moved
# underneath a transition refuses with bd's exit 13 and changes nothing.
#
# CRASH RECOVERY. Only teardown needs a durable record: it removes the meta and
# with it the completion links, so a process killed between the two halves would
# leave nothing to reconstruct the close from. It writes
# `state/<id>.backlog-close` first, and removes it once the close lands.
# The writer and replay share one complete-record validator, and teardown stages
# that record before destructive cleanup, so it never publishes or acts on a close
# replay would reject. The validator pins the data path to this home's configured
# root before any recovery mutation, then re-runs exactly that close.
# While matching task metadata still exists, a scratch registry (including a
# symlink) or data/<id>/ directory blocks replay before metadata removal: rerun
# teardown to finish process and scratch cleanup instead of losing ownership.
# `done` on an already-closed task backfills links
# without moving the close date, so replay is idempotent. Spawn needs no marker:
# it publishes the meta first, so a crash
# leaves the meta itself as the evidence that the row is owed a start.
# A captain-held row uses the same record with a `mode=retain` line: replay then
# records the deliverable and reopens the row instead of closing it, and never
# closes a row that reads as an open captain call. An answer that closes the row
# first applies any supported retained artifact from the validated record, then
# replay simply retires the record.

# Set by jg_backlog_transition_applies for a return-1 exemption.
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
JG_BACKLOG_TRANSITION_SKIP=
# Set by the mutating helpers when they return non-zero.
JG_BACKLOG_TRANSITION_ERROR=
JG_BACKLOG_ROW_RESULT=
JG_BACKLOG_ROW_STATE=
JG_BACKLOG_ROW_ERROR=
# Set by jg_backlog_row_probe on a found row: the hold kind, empty when
# the row is not held.
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
JG_BACKLOG_ROW_HOLD_KIND=
# Set by jg_backlog_close_marker_replay: closed | closed_incomplete | retained |
# retained_incomplete | answered | stale | noop.
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
JG_BACKLOG_CLOSE_REPLAY_RESULT=

# Bounded execution is jg-timeout-lib.sh's alone; source it rather than
# re-deriving a deadline here.
# shellcheck source=bin/jg-timeout-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jg-timeout-lib.sh"
# jg-pr-lib.sh owns which URL is a Gerrit change. It is functions and empty
# globals only, so it is sourced once rather than re-initialising a caller's
# parsed identity.
if ! declare -F jg_pr_url_parse >/dev/null 2>&1; then
  # shellcheck source=bin/jg-pr-lib.sh disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jg-pr-lib.sh"
fi

# Latched when a row read hits its bound. jg_backlog_row_show runs inside a
# command substitution, so the subshell can READ this latch but cannot set it;
# the callers that capture its status own the write.
JG_BACKLOG_ROW_SHOW_WEDGED=0

# Emit each byte of a value as a decimal number, locale-independently.
# Deliberately perl rather than od: the spawn and teardown lifecycle runs under a
# curated PATH (tests/jg-teardown.test.sh make_path_without_lsof pins that set)
# that excludes od, and a validator that cannot run must never wedge dispatch or
# cleanup. perl is already in that curated set and is already used elsewhere in
# this repo for the same portability reason.
jg_backlog_bytes_of_string() {  # <string>
  perl -e 'print join(" ", unpack("C*", $ARGV[0])), "\n"' -- "$1"
}

jg_backlog_bytes_of_file() {  # <path>
  perl -e 'open(my $f, "<", $ARGV[0]) or exit 1; binmode $f; local $/; my $c = <$f>; $c = "" unless defined $c; print join(" ", unpack("C*", $c)), "\n"' -- "$1"
}

jg_backlog_control_bytes_valid() {  # <allow-newline: 0|1> <od-bytes>
  printf '%s\n' "$2" | awk -v allow_newline="$1" '
    { for (i = 1; i <= NF; i++) if (($i < 32 && !(allow_newline && $i == 10)) || $i == 127) exit 1 }
  '
}

jg_backlog_directory_present() {
  local path=$1 label=$2 check=$1
  while [ "$check" != / ] && [ "${check%/}" != "$check" ]; do
    check=${check%/}
  done
  if [ ! -d "$check" ] || [ -L "$check" ]; then
    JG_BACKLOG_TRANSITION_ERROR="$label is not a real directory at $path"
    return 1
  fi
}

jg_backlog_data_absolute() {
  local data=$1 raw_bytes check
  raw_bytes=$(jg_backlog_bytes_of_string "$data") || return 1
  if ! jg_backlog_control_bytes_valid 0 "$raw_bytes"; then
    printf 'error: data directory contains an invalid control byte\n' >&2
    return 2
  fi
  check=$data
  while [ "$check" != / ] && [ "${check%/}" != "$check" ]; do
    check=${check%/}
  done
  if [ ! -d "$check" ]; then
    JG_BACKLOG_TRANSITION_ERROR="data directory is not a directory at $data"
    return 1
  fi
  if ! data=$(CDPATH='' cd -- "$data" 2>/dev/null && pwd -P); then
    return 1
  fi
  printf '%s\n' "$data"
}

jg_backlog_file() {  # <data-dir>
  local data
  data=$(jg_backlog_data_absolute "$1") || {
    JG_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $1"
    return 1
  }
  if [ "$data" = / ]; then
    printf '/backlog.md\n'
  else
    printf '%s/backlog.md\n' "$data"
  fi
}

# The directory that holds the data directory.
jg_backlog_root() {  # <data-dir>
  local data parent
  data=$(jg_backlog_data_absolute "$1") || {
    JG_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $1"
    return 1
  }
  case "$data" in
    */*)
      parent=${data%/*}
      [ -n "$parent" ] || parent=/
      ;;
    *) parent=. ;;
  esac
  printf '%s\n' "$parent"
}

jg_backlog_data_relative() {  # <data-dir>
  local data root
  data=$(jg_backlog_data_absolute "$1") || {
    JG_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $1"
    return 1
  }
  root=$(jg_backlog_root "$data") || return 1
  if [ "$data" = "$root" ]; then
    printf '.\n'
    return 0
  fi
  if [ "$root" = / ]; then
    printf '%s\n' "${data#/}"
    return 0
  fi
  case "$data" in
    "$root"/*) printf '%s\n' "${data#"$root"/}" ;;
    *) printf '%s\n' "$data" ;;
  esac
}


# The config directory of the home that owns <data>, by jg_backlog_ticket_publish's rule.
jg_backlog_config_of() {  # <data-dir>
  printf '%s\n' "${JG_CONFIG_OVERRIDE:-${JG_HOME:-${1%/*}}/config}"
}

# The data boundary is authorized first and unconditionally; the Beads store
# keeps no backlog file, so only the data directory's parent is checked.
jg_backlog_source_present() {  # <data-dir> <authorized-data-dir>
  local data=$1 authorized_data=$2 file
  file=$(jg_backlog_file "$data") || return 1
  jg_backlog_record_parent_authorized "$file" "backlog data directory" "$authorized_data" parent-only
}

# Resolve how the owning home's backlog is addressed, for reads and mutations
# alike: sets JG_BACKLOG_AXI_ROOT to the cd target and JG_BACKLOG_AXI_BEADS to
# the config directory of the home. This is the single place that decision is
# made. The caller invokes jg_backlog_serve inside its own subshell - the bound
# wrapper execs, so a nested subshell here would add a process layer between the
# store tool and the caller, which the lock-holding callers' interruption
# contract counts on not existing.
jg_backlog_addressing() {  # <data-dir>
  local data root config
  data=$(jg_backlog_data_absolute "$1") || return $?
  root=$(jg_backlog_root "$data") || return $?
  config=$(jg_backlog_config_of "$data")
  JG_BACKLOG_AXI_ROOT=$root
  JG_BACKLOG_AXI_BEADS=$config
}

jg_backlog_transition_applies() {  # <config-dir> <data-dir> <kind>
  local config=$1 authorized_data=$2 kind=$3
  JG_BACKLOG_TRANSITION_SKIP=
  if [ "$kind" = squad_lead ]; then
    JG_BACKLOG_TRANSITION_SKIP="squad_leads are not backlog items"
    return 1
  fi
  jg_backlog_data_absolute "$2" >/dev/null || {
    JG_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $2"
    return 2
  }
  if ! JG_BACKLOG_TRANSITION_ERROR=$(jg_backlog_beads_store "$config" 2>&1 >/dev/null); then
    return 2
  fi
  jg_backlog_source_present "$2" "$authorized_data" || return 2
  return 0
}

# Run the Beads provider with an optional JG_BACKLOG_TIMEOUT bound. A caller that
# holds a lock across the call - the spawn commit and its preservation
# read-back run under the per-task meta lock - sets the bound, so an
# unresponsive store cannot hold that lock open indefinitely. The bound is
# jg_exec_timed's (bin/jg-timeout-lib.sh), with one further bound of grace
# before KILL so a store that ignores SIGTERM cannot outlive it either; the
# callers treat jg_timed_out statuses as the bound expiring and report the
# timeout as the reason through their existing error plumbing. A bound that
# cannot be enforced on this host stops safely instead of running unbounded.
# Must be the last command of a subshell: the exec keeps the process exactly
# where the plain call sat, and the bound kills the child, not the caller.
jg_backlog_timeout_expired() {  # <status>
  jg_timed_out "$1"
}

# JG_BACKLOG_TOOL is the command that answers a verb for the addressing just
# resolved: a shell serving the Beads provider.
jg_backlog_tool() {
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  JG_BACKLOG_TOOL=(bash -c '. "$1"; shift; jg_backlog_beads_serve "$@"' jg-beads
    "$(dirname "${BASH_SOURCE[0]}")/jg-backlog-lib.sh" "$JG_BACKLOG_AXI_BEADS")
}

jg_backlog_serve() {
  local bound=${JG_BACKLOG_TIMEOUT:-}
  jg_backlog_tool
  if [ -z "$bound" ]; then
    exec "${JG_BACKLOG_TOOL[@]}" "$@"
  fi
  jg_exec_timed "$bound" "$bound" "${JG_BACKLOG_TOOL[@]}" "$@"
}

# Print one row's `show` output (plus stderr) from the addressing
# jg_backlog_addressing resolved. Addressing errors return before the store
# runs; otherwise its exit status is preserved. Extra flags (--full) pass through.
#
# Every read is bounded, because a wedged backend read here is what blinds a
# whole session start: bin/jg-bootstrap.sh's reconcile and close-replay sweeps
# call this once per item, and one unbounded read consumes the entire
# JG_SESSION_START_TIMEOUT and truncates the digest before the wake queue,
# supervision instructions, fleet state and context sections ever print. The
# bound turns that into a loud partial reconcile: the caller reports the item it
# could not read and moves to the next one.
#
# One slow read is not a wedge: on a slow host a single `show` can pass the base
# bound while the backend is healthy, and refusing at once there refused the
# cleanup of landed lanes and the captain holds that need this read. So a read
# that hits its bound is retried, each attempt with a larger bound (the base
# bound times the attempt number, three attempts), which
# keeps the total bounded at the base bound times 1+2+3. Only a read that is
# still timed out after the last attempt is a wedge: it returns 124 once, and
# its first line names the attempts and their bounds.
#
# A per-item bound alone is not enough on a home carrying a large fleet, because
# N wedged items still cost N bounds and the digest is truncated anyway. So the
# first wedge latches JG_BACKLOG_ROW_SHOW_WEDGED and every later read in the
# same sweep returns immediately, still naming its own item so nothing is
# silently skipped. This function only READS that latch: it runs inside a
# command substitution, and a write here would die with the subshell, so the
# callers that capture its status set it. They see a 124 only after the last
# attempt, so a read that a retry rescued never latches the sweep. The latch is
# deliberately process-wide because these scripts are short-lived and a backend
# that wedged through every attempt will wedge again within the same run.
jg_backlog_row_show() {  # <resolved-data-dir> <id> [flag...]
  local data=$1 id=$2 out status addressing_status secs=${JG_BACKLOG_ROW_TIMEOUT_SECS:-10}
  local attempt=1 attempts=3 bound bounds=
  shift 2
  # A non-positive bound is not a bound (jg-timeout-lib.sh), and a padded zero
  # such as 00 is still zero, so the digits test alone would let the very read
  # this bound exists to prevent back in. Compare arithmetically, tolerating a
  # value too large for the shell to compare at all. A value past a day is no
  # bound either, and keeps the retried bounds below far from overflow.
  case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
  [ "$secs" -gt 0 ] 2>/dev/null || secs=10
  [ "$secs" -le 86400 ] 2>/dev/null || secs=10
  jg_backlog_addressing "$data"
  addressing_status=$?
  if [ "$addressing_status" -ne 0 ]; then
    [ -z "${JG_BACKLOG_TRANSITION_ERROR:-}" ] || printf '%s\n' "$JG_BACKLOG_TRANSITION_ERROR" >&2
    return "$addressing_status"
  fi
  if [ "$JG_BACKLOG_ROW_SHOW_WEDGED" = 1 ]; then
    printf 'backlog show %s skipped: the backlog backend already exceeded its read bound on every attempt\n' "$id"
    return 124
  fi
  jg_backlog_tool
  while :; do
    bound=$((secs * attempt))
    # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
    out=$(jg_run_timed "$bound" bash -c 'cd "$1" 2>/dev/null || exit 1; shift; exec "$@"' \
      _ "$JG_BACKLOG_AXI_ROOT" "${JG_BACKLOG_TOOL[@]}" show "$id" "$@" 2>&1)
    status=$?
    [ "$status" -eq 124 ] || break
    bounds=${bounds:+$bounds, }${bound}s
    [ "$attempt" -lt "$attempts" ] || break
    attempt=$((attempt + 1))
  done
  # A backend that wrote a header or a progress line before wedging leaves that
  # fragment as the first output line, and every caller reads the first line as
  # the failure reason. Whatever a timed-out read managed to emit is incomplete
  # by definition, so the bound speaks for it instead. The wording up to
  # "backlog read bound" is matched by bin/jg-trunk.sh's landing retry.
  if [ "$status" -eq 124 ]; then
    printf 'backlog show %s exceeded its %ss backlog read bound after %s attempts (%s)\n' "$id" "$bound" "$attempt" "$bounds"
  else
    printf '%s\n' "$out"
  fi
  return "$status"
}

jg_backlog_row_list() {  # <resolved-data-dir> [flag...]
  local data=$1 addressing_status
  shift
  jg_backlog_addressing "$data"
  addressing_status=$?
  if [ "$addressing_status" -ne 0 ]; then
    [ -z "${JG_BACKLOG_TRANSITION_ERROR:-}" ] || printf '%s\n' "$JG_BACKLOG_TRANSITION_ERROR" >&2
    return "$addressing_status"
  fi
  (cd "$JG_BACKLOG_AXI_ROOT" 2>/dev/null && jg_backlog_serve list "$@" 2>&1)
}

jg_backlog_row_probe() {  # <data-dir> <id>
  local data authorized_data=$1 id=$2 out state held blocked hold_kind command_status source_status
  if ! data=$(jg_backlog_data_absolute "$1"); then
    JG_BACKLOG_ROW_RESULT=error
    JG_BACKLOG_ROW_STATE=
    JG_BACKLOG_ROW_ERROR="data directory cannot be resolved: $1"
    return 1
  fi
  JG_BACKLOG_ROW_RESULT=error
  JG_BACKLOG_ROW_STATE=
  JG_BACKLOG_ROW_HOLD_KIND=
  JG_BACKLOG_ROW_ERROR=
  jg_backlog_source_present "$data" "$authorized_data"
  source_status=$?
  if [ "$source_status" -ne 0 ]; then
    JG_BACKLOG_ROW_ERROR=$JG_BACKLOG_TRANSITION_ERROR
    return "$source_status"
  fi
  out=$(jg_backlog_row_show "$data" "$id")
  command_status=$?
  [ "$command_status" -ne 124 ] || JG_BACKLOG_ROW_SHOW_WEDGED=1
  if [ "$command_status" -ne 0 ]; then
    if printf '%s\n' "$out" | grep -q '^code: NOT_FOUND$'; then
      JG_BACKLOG_ROW_RESULT=not_found
    else
      JG_BACKLOG_ROW_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
      if [ -z "$JG_BACKLOG_ROW_ERROR" ]; then
        if jg_backlog_timeout_expired "$command_status" && [ -n "${JG_BACKLOG_TIMEOUT:-}" ]; then
          JG_BACKLOG_ROW_ERROR="backlog show $id did not finish within ${JG_BACKLOG_TIMEOUT}s"
        else
          JG_BACKLOG_ROW_ERROR="backlog show $id failed with no output"
        fi
      fi
    fi
    return "$command_status"
  fi
  state=$(printf '%s\n' "$out" | sed -n 's/^  state: *//p' | head -1)
  held=$(printf '%s\n' "$out" | sed -n 's/^  held: *//p' | head -1)
  blocked=$(printf '%s\n' "$out" | sed -n 's/^  blocked: *//p' | head -1)
  hold_kind=$(printf '%s\n' "$out" | sed -n 's/^  hold_kind: *//p' | head -1)
  if [ -z "$state" ]; then
    JG_BACKLOG_ROW_ERROR="backlog show $id returned no state"
    return 1
  fi
  JG_BACKLOG_ROW_RESULT=found
  JG_BACKLOG_ROW_STATE="$state ${held:-no} ${blocked:-no}"
  case "$hold_kind" in
    ''|'"-"'|-) JG_BACKLOG_ROW_HOLD_KIND= ;;
    *) JG_BACKLOG_ROW_HOLD_KIND=$hold_kind ;;
  esac
  return 0
}

# A sweep that pairs many task records with their rows reads the backlog once, not once per record (a home with 87
# records paid 87 reads of 2.6 to 4.7 s). jg_backlog_row_snapshot fills JG_BACKLOG_ROW_SNAPSHOT with one
# "<item> <state> <held> <blocked>" line per row, closed rows included (the item is the name the home's records use:
# the task id of a ticket that was spawned under one, else the row id), and jg_backlog_row_snapshot_probe answers
# jg_backlog_row_probe's question from it: the same JG_BACKLOG_ROW_RESULT and JG_BACKLOG_ROW_STATE, found or not_found.
# A list read that fails as a whole returns 1 with JG_BACKLOG_ROW_ERROR, and the caller falls back to jg_backlog_row_probe.
# Only the last three fields and the second are read, so a quoted title holding commas cannot shift them.
JG_BACKLOG_ROW_SNAPSHOT=
jg_backlog_row_snapshot() {  # <data-dir>
  local data out status
  JG_BACKLOG_ROW_SNAPSHOT=
  JG_BACKLOG_ROW_ERROR=
  if ! data=$(jg_backlog_data_absolute "$1"); then
    JG_BACKLOG_ROW_ERROR="data directory cannot be resolved: $1"
    return 1
  fi
  if ! jg_backlog_source_present "$data" "$1"; then
    JG_BACKLOG_ROW_ERROR=$JG_BACKLOG_TRANSITION_ERROR
    return 1
  fi
  out=$(JG_BACKLOG_TIMEOUT=${JG_BACKLOG_TIMEOUT:-60} jg_backlog_row_list "$data" --all --fields held,blocked,item)
  status=$?
  if [ "$status" -ne 0 ] || ! printf '%s\n' "$out" | grep -q '^\(count: \|tasks: 0 \)'; then
    JG_BACKLOG_ROW_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
    [ -n "$JG_BACKLOG_ROW_ERROR" ] || JG_BACKLOG_ROW_ERROR="backlog list failed with status $status"
    return 1
  fi
  JG_BACKLOG_ROW_SNAPSHOT=$(printf '%s\n' "$out" | awk -F, '/^  [A-Za-z0-9._-]+,/ {
    print $NF " " $2 " " $(NF - 2) " " $(NF - 1) }')
}

jg_backlog_row_snapshot_probe() {  # <id>
  local state
  state=$(printf '%s\n' "$JG_BACKLOG_ROW_SNAPSHOT" | awk -v id="$1" '$1 == id { print $2 " " $3 " " $4; exit }')
  JG_BACKLOG_ROW_ERROR=
  JG_BACKLOG_ROW_HOLD_KIND=
  if [ -z "$state" ]; then
    JG_BACKLOG_ROW_RESULT=not_found
    JG_BACKLOG_ROW_STATE=
    return 1
  fi
  JG_BACKLOG_ROW_RESULT=found
  JG_BACKLOG_ROW_STATE=$state
}

# Write the ticket the moment a backlog row moves, so the board the captain reads
# follows the work itself instead of waiting for the next tickets-sync poll.
# bin/jg-ticket.sh owns the write: it takes this home's board, writes only fields
# that differ, and is a silent no-op (exit 0) when this home has no board, so a
# board problem never fails a transition. The mapping is the poll's own
# (core/tickets-sync/sync.py owns state, stage and progress), and `update` moves
# no stage, so it writes nothing.
# Usage: jg_backlog_ticket_note <data-dir> <verb> <id> [flag...]
jg_backlog_ticket_note() {  # <data-dir> <verb> <id> [flag...]
  local data=$1 verb=$2 id=$3 home tool pr='' reason='' note_out
  local -a args=()
  shift 3
  case "$verb" in
    start) args=(--stage building --state 'in progress') ;;
    done|close) args=(--stage "done" --state "done") ;;
    reopen) args=(--stage queued --state queued) ;;
    hold|park) args=(--state 'on hold') ;;
    unhold) args=(--state queued) ;;
    *) return 0 ;;
  esac
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --pr ] && { [ "$verb" = "done" ] || [ "$verb" = "close" ]; }; then pr=${2-}; fi
    if [ "$1" = --reason ] && { [ "$verb" = hold ] || [ "$verb" = park ]; }; then reason=${2-}; fi
    shift
  done
  [ -z "$pr" ] || args+=(--pr "$pr")
  [ -z "$reason" ] || args+=(--hold-reason "$reason")
  home=${JG_HOME:-${data%/*}}
  tool=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/jg-ticket.sh
  [ -x "$tool" ] || return 0
  note_out=$(JG_HOME=$home "$tool" "$id" "${args[@]}" 2>&1) \
    || jg_backlog_mirror_behind "$id" "$note_out"
  case "$verb" in done|close) jg_backlog_ticket_publish "$data" "$verb" "$id" ;; esac
  return 0
}

# Say, never silently, that the board no longer matches the backlog. The backlog
# write already succeeded and stays; the next tickets-sync poll catches the board up.
jg_backlog_mirror_behind() {  # <id> <cause>
  printf 'jg-backlog: board mirror is behind for %s (the backlog write succeeded; the next tickets-sync poll will catch up): %s\n' \
    "$1" "$(printf '%s' "${2:-no cause given}" | sed -n '1p')" >&2
}

# Make the board show a backlog write now. The poll (core/tickets-sync/sync.py) owns
# creating a ticket and is idempotent through its ledger, so running it here puts an
# added row on the board and closes a done one with nobody running a sync by hand,
# and running it twice changes nothing. A home with no fleet board, or no installed
# sync, is a silent no-op. Anything else that leaves the board unlike the backlog is
# reported on stderr and still returns 0, so a board problem never fails a write.
# Usage: jg_backlog_ticket_publish <data-dir> <add|done|close> <id>
jg_backlog_ticket_publish() {  # <data-dir> <verb> <id>
  local data=$1 verb=$2 id=$3 home sync pointer board tool tid out want
  home=${JG_HOME:-${data%/*}}
  sync=${JG_TICKETS_SYNC:-${XDG_DATA_HOME:-${HOME:-}/.local/share}/jg-tickets-sync/tickets-sync/sync.py}
  pointer=${JG_CONFIG_OVERRIDE:-$home/config}/fleet-board
  [ -f "$sync" ] && [ -f "$pointer" ] || return 0
  if [ -s "$home/.jg-squad-lead-home" ] && [ "$(tr -d '[:space:]' < "$home/.jg-squad-lead-home")" != main ]; then
    printf 'jg-backlog: the parent poll publishes %s to the board\n' "$id" >&2
    return 0
  fi
  IFS= read -r board < "$pointer" || true
  case "$board" in /*) ;; *) board=$home/$board ;; esac
  tool=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/jg-ticket.sh
  tid=$("$tool" id "$id" 2>/dev/null) || return 0
  if ! command -v python3 >/dev/null 2>&1 || ! command -v sign-off-axi >/dev/null 2>&1; then
    jg_backlog_mirror_behind "$id" 'python3 and sign-off-axi are needed to publish the ticket'
    return 0
  fi
  out=$(JG_HOME=$home timeout "${JG_TICKETS_PUBLISH_SECS:-90}" python3 "$sync" 2>&1) \
    || { jg_backlog_mirror_behind "$id" "$out"; return 0; }
  want='.ticket != null'
  case "$verb" in done|close) want='.ticket.state == "done"' ;; esac
  sign-off-axi ticket "$board" --id "$tid" --json 2>/dev/null | jq -e "$want" >/dev/null 2>&1 \
    || jg_backlog_mirror_behind "$id" "the board does not show it yet${out:+: $out}"
  return 0
}

# Run one backlog mutation against <home>'s backlog, capturing its first
# output line in JG_BACKLOG_TRANSITION_ERROR on failure. The home boundary is
# authorized through jg_backlog_source_present first; jg_backlog_addressing owns
# how the store is addressed (ADDRESSING above).
jg_backlog_mutate() {  # <data-dir> <verb> <id> [flag...]
  local data authorized_data=$1 verb=$2 id=$3 out command_status source_status
  if ! data=$(jg_backlog_data_absolute "$1"); then
    JG_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $1"
    return 1
  fi
  shift 3
  JG_BACKLOG_TRANSITION_ERROR=
  jg_backlog_source_present "$data" "$authorized_data"
  source_status=$?
  [ "$source_status" -eq 0 ] || return "$source_status"
  jg_backlog_addressing "$data"
  source_status=$?
  [ "$source_status" -eq 0 ] || return "$source_status"
  out=$(cd "$JG_BACKLOG_AXI_ROOT" 2>/dev/null && jg_backlog_serve "$verb" "$id" "$@" 2>&1)
  command_status=$?
  [ "$command_status" -ne 0 ] || { jg_backlog_ticket_note "$data" "$verb" "$id" "$@"; return 0; }
  JG_BACKLOG_TRANSITION_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
  if [ -z "$JG_BACKLOG_TRANSITION_ERROR" ]; then
    if jg_backlog_timeout_expired "$command_status" && [ -n "${JG_BACKLOG_TIMEOUT:-}" ]; then
      JG_BACKLOG_TRANSITION_ERROR="backlog $verb $id did not finish within ${JG_BACKLOG_TIMEOUT}s"
    else
      JG_BACKLOG_TRANSITION_ERROR="backlog $verb $id failed with no output"
    fi
  fi
  return "$command_status"
}

jg_backlog_start() {  # <data-dir> <id>
  jg_backlog_mutate "$1" start "$2"
}

# A row names the worker that owns it: the Herdr agent name of the task id as the
# assignee, the same across a relaunch, with the spawn generation in the task
# record as metadata.lane and the record's harness as metadata.agent.
# bin/jg-beads-write.py owns the claim and its refusal of a second spawn.
jg_backlog_lane_start() {  # <meta> <data-dir> <id> <state-dir>
  local meta=$1 data=$2 id=$3 state=$4 agent name
  jg_backlog_meta_spawn_gen_optional "$meta" "$state" || return 1
  agent=$(LC_ALL=C sed -n 's/^harness=//p' "$meta" | tail -n 1)
  name=$("${BASH_SOURCE[0]%/*}/jg-herdr.sh" agent-name-for "$id") || {
    JG_BACKLOG_TRANSITION_ERROR="no agent name for task $id"
    return 1
  }
  JG_BACKLOG_LANE=$name JG_BACKLOG_SPAWN_GEN=$JG_BACKLOG_META_SPAWN_GEN JG_BACKLOG_AGENT=$agent jg_backlog_start "$data" "$id"
}

# A row already In flight needs no move, so only Beads has work here: the new
# lane claims it, or takes it from the lane this spawn replaces on a relaunch.
jg_backlog_lane_claim() {  # <meta> <data-dir> <id> <state-dir>
  jg_backlog_lane_start "$@"
}

jg_backlog_lane_handover() {  # <meta> <data-dir> <id> <state-dir>
  JG_BACKLOG_LANE_HANDOVER=1 jg_backlog_lane_claim "$@"
}

# The backlog takes a --pr link only as a canonical GitHub or Forgejo pull request
# and refuses anything else, so a Gerrit change URL is recorded on the row as a
# note instead. The subshell keeps the parse from overwriting a caller's
# JG_PR_* identity.
jg_backlog_pr_is_gerrit_change() {  # <url>
  ( jg_pr_url_parse "$1" && [ "$JG_PR_PROVIDER" = gerrit ] )
}

jg_backlog_done() {  # <data-dir> <id> [flag...]
  local data=$1 id=$2 arg previous_arg=''
  local -a done_args=()
  shift 2
  for arg in "$@"; do
    if [ "$previous_arg" = --pr ] && jg_backlog_pr_is_gerrit_change "$arg"; then
      done_args[${#done_args[@]}-1]=--note
      done_args+=("Gerrit change $arg")
    else
      done_args+=("$arg")
    fi
    previous_arg=$arg
  done
  jg_backlog_mutate "$data" "done" "$id" "${done_args[@]+"${done_args[@]}"}"
}

jg_backlog_row_artifact_supported() {
  local id=$1 flag=${2:-} value=${3:-}
  case "$flag" in
    --pr) ! jg_backlog_pr_is_gerrit_change "$value" ;;
    --report) [ "$value" = "data/$id/report.md" ] ;;
    *) return 1 ;;
  esac
}

# Keep a captain-held row open across the removal of the work record that
# discovered it: record the finished work's deliverable as one line at the end
# of the task body (a line already present is left alone), preserve supported
# artifacts on the row, and return it to Queued, the conventional post-cleanup
# shape for an open captain call.
# bin/jg-fleet-snapshot.sh classifies that retained hold from its structured
# fields; only bin/jg-captain-hold.sh answer resolves the call.
jg_backlog_retain() {  # <data-dir> <id> [flag...]
  local data authorized_data=$1 id=$2 out command_status previous_arg=''
  local arg deliverable='' line body new_body tmp
  local -a row_args=()
  if ! data=$(jg_backlog_data_absolute "$1"); then
    JG_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $1"
    return 1
  fi
  shift 2
  JG_BACKLOG_TRANSITION_ERROR=
  for arg in "$@"; do
    case "$previous_arg" in
      --report)
        deliverable="${deliverable:+$deliverable; }report $arg"
        if jg_backlog_row_artifact_supported "$id" --report "$arg"; then
          row_args=(--report "$arg")
        fi
        ;;
      --pr)
        if jg_backlog_row_artifact_supported "$id" --pr "$arg"; then
          deliverable="${deliverable:+$deliverable; }PR $arg"
          row_args=(--pr "$arg")
        else
          deliverable="${deliverable:+$deliverable; }Gerrit change $arg"
        fi
        ;;
      --note) deliverable="${deliverable:+$deliverable; }$arg" ;;
    esac
    previous_arg=$arg
  done
  if [ -n "$deliverable" ]; then
    out=$(jg_backlog_row_show "$data" "$id" --full)
    command_status=$?
    [ "$command_status" -ne 124 ] || JG_BACKLOG_ROW_SHOW_WEDGED=1
    if [ "$command_status" -ne 0 ]; then
      JG_BACKLOG_TRANSITION_ERROR=$(printf '%s\n' "$out" | sed -n '1p')
      [ -n "$JG_BACKLOG_TRANSITION_ERROR" ] \
        || JG_BACKLOG_TRANSITION_ERROR="backlog show $id failed with no output"
      return "$command_status"
    fi
    # The leading quote selects a JSON-encoded bare string, which is exactly the
    # value an older JSON::PP rejects unless allow_nonref is asked for, so the
    # decoder below requests it rather than inheriting the local default. It then
    # writes bytes, because printing the decoded characters to a stream with no
    # :raw layer emits a codepoint at or below U+00FF as one latin-1 byte and
    # silently corrupts the body this rewrites.
    body=$(printf '%s\n' "$out" | sed -n 's/^  body: //p' | head -1 \
      | LC_ALL=C perl -MJSON::PP -e '
        local $/;
        my $shown = <STDIN>;
        $shown =~ s/\s+\z//;
        exit 0 if $shown eq "" || $shown eq "-";
        my $value = $shown =~ /\A"/
          ? JSON::PP->new->utf8->allow_nonref->decode($shown) : $shown;
        binmode STDOUT, ":raw";
        utf8::encode($value) if utf8::is_utf8($value);
        print $value unless $value eq "-";
      ') || {
      JG_BACKLOG_TRANSITION_ERROR="could not decode the task body of $id"
      return 1
    }
    line="Deliverable of the finished work: $deliverable"
    case $'\n'"$body"$'\n' in
      *$'\n'"$line"$'\n'*) ;;
      *)
        new_body=$line
        [ -z "$body" ] || new_body=$(printf '%s\n\n%s' "$body" "$line")
        tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/jg-backlog-retain-body.XXXXXX") || {
          JG_BACKLOG_TRANSITION_ERROR="cannot stage the deliverable for $id"
          return 1
        }
        if ! printf '%s\n' "$new_body" > "$tmp"; then
          rm -f -- "$tmp"
          JG_BACKLOG_TRANSITION_ERROR="cannot stage the deliverable for $id"
          return 1
        fi
        if ! jg_backlog_mutate "$authorized_data" update "$id" --body-file "$tmp"; then
          rm -f -- "$tmp"
          return 1
        fi
        rm -f -- "$tmp"
        ;;
    esac
  fi
  if [ "${#row_args[@]}" -gt 0 ]; then
    jg_backlog_mutate "$authorized_data" update "$id" "${row_args[@]}" || return 1
  fi
  jg_backlog_mutate "$authorized_data" reopen "$id"
}

jg_backlog_canonical_existing() {
  LC_ALL=C perl -MCwd=realpath -e '
    my $resolved = realpath($ARGV[0]);
    exit 1 unless defined $resolved;
    print $resolved;
  ' "$1" 2>/dev/null
}

jg_backlog_record_parent_authorized() {  # <path> <label> <root> [parent-only]
  local path=$1 label=$2 root=$3 parent_only=${4:-} parent base parent_resolved expected_path
  local path_resolved root_resolved root_prefix home_resolved final_matches=1
  parent=${path%/*}
  [ "$parent" != "$path" ] || parent=.
  base=${path##*/}
  root_resolved=$(jg_backlog_canonical_existing "$root") || {
    JG_BACKLOG_TRANSITION_ERROR="$label authorized directory cannot be resolved at $root"
    return 1
  }
  [ -d "$root_resolved" ] || {
    JG_BACKLOG_TRANSITION_ERROR="$label authorized directory is not a directory at $root"
    return 1
  }
  if [ -n "${JG_HOME:-}" ]; then
    case "$root" in
      "$JG_HOME"|"$JG_HOME"/*)
        home_resolved=$(jg_backlog_canonical_existing "$JG_HOME") || {
          JG_BACKLOG_TRANSITION_ERROR="$label home directory cannot be resolved at $JG_HOME"
          return 1
        }
        case "$root_resolved" in
          "$home_resolved"|"$home_resolved"/*) ;;
          *)
            JG_BACKLOG_TRANSITION_ERROR="$label authorized directory resolves outside this home at $root"
            return 1
            ;;
        esac
        ;;
    esac
  fi
  parent_resolved=$(jg_backlog_canonical_existing "$parent") || {
    JG_BACKLOG_TRANSITION_ERROR="$label parent directory cannot be resolved at $path"
    return 1
  }
  expected_path=${parent_resolved%/}/$base
  if [ -z "$parent_only" ] && { [ -e "$path" ] || [ -L "$path" ]; }; then
    path_resolved=$(jg_backlog_canonical_existing "$path") || {
      JG_BACKLOG_TRANSITION_ERROR="$label cannot be resolved at $path"
      return 1
    }
    [ "$path_resolved" = "$expected_path" ] || final_matches=0
  else
    path_resolved=$expected_path
  fi
  root_prefix=${root_resolved%/}/
  case "$path_resolved" in
    "$root_prefix"*) ;;
    *)
      JG_BACKLOG_TRANSITION_ERROR="$label resolves outside its authorized directory at $path"
      return 1
      ;;
  esac
  if [ "$final_matches" != 1 ]; then
    JG_BACKLOG_TRANSITION_ERROR="$label resolves through a different final path at $path"
    return 1
  fi
}

jg_backlog_record_present() {
  local path=$1 label=${2:-record} root=$3
  jg_backlog_record_parent_authorized "$path" "$label" "$root" || return 1
  if [ ! -f "$path" ]; then
    JG_BACKLOG_TRANSITION_ERROR="$label is not a regular file at $path"
    return 1
  fi
  return 0
}

jg_backlog_record_remove() {
  local path=$1 label=$2 root=$3
  jg_backlog_record_parent_authorized "$path" "$label" "$root" || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    jg_backlog_record_present "$path" "$label" "$root" || return 1
  fi
  if ! rm -f "$path" 2>/dev/null || [ -e "$path" ] || [ -L "$path" ]; then
    JG_BACKLOG_TRANSITION_ERROR="$label could not be removed at $path"
    return 1
  fi
  return 0
}

jg_backlog_record_publish() {
  local source=$1 target=$2 label=$3 root=$4
  jg_backlog_record_present "$source" "$label staged record" "$root" || return 1
  jg_backlog_record_parent_authorized "$target" "$label target" "$root" || return 1
  if [ -e "$target" ] || [ -L "$target" ]; then
    jg_backlog_record_present "$target" "$label target" "$root" || return 1
  fi
  if ! mv -f "$source" "$target" 2>/dev/null || ! jg_backlog_record_present "$target" "$label" "$root"; then
    [ -n "$JG_BACKLOG_TRANSITION_ERROR" ] \
      || JG_BACKLOG_TRANSITION_ERROR="$label publication failed at $target"
    return 1
  fi
  return 0
}

jg_backlog_meta_spawn_gen() {
  local meta=$1 state=$2 count value
  JG_BACKLOG_META_SPAWN_GEN=
  jg_backlog_record_present "$meta" "task record" "$state" || return 1
  count=$(LC_ALL=C awk -F= '$1 == "spawn_gen" { count++ } END { print count + 0 }' "$meta" 2>/dev/null) || {
    JG_BACKLOG_TRANSITION_ERROR="unreadable spawn generation in task record $meta"
    return 1
  }
  if [ "$count" -ne 1 ]; then
    JG_BACKLOG_TRANSITION_ERROR="task record $meta has $count spawn generation fields; exactly one is required"
    return 1
  fi
  value=$(LC_ALL=C awk -F= '$1 == "spawn_gen" { sub(/^[^=]*=/, ""); print }' "$meta" 2>/dev/null) || {
    JG_BACKLOG_TRANSITION_ERROR="unreadable spawn generation in task record $meta"
    return 1
  }
  case "$value" in
    ''|.*|*[!A-Za-z0-9._-]*)
      JG_BACKLOG_TRANSITION_ERROR="invalid spawn generation in task record $meta"
      return 1
      ;;
  esac
  JG_BACKLOG_META_SPAWN_GEN=$value
}

# The same incarnation, read for a caller that only needs to notice a CHANGE.
# A record predating the field carries no incarnation to compare, so it yields
# an empty value and proceeds instead of refusing; comparing that empty value
# across a wait still catches a record that gained, lost, or altered one. An
# ambiguous or unreadable field is still an error, because a record that cannot
# name one exact incarnation cannot be compared at all.
jg_backlog_meta_spawn_gen_optional() {  # <meta> <state>
  local meta=$1 state=$2 count
  JG_BACKLOG_META_SPAWN_GEN=
  jg_backlog_record_present "$meta" "task record" "$state" || return 1
  count=$(LC_ALL=C awk -F= '$1 == "spawn_gen" { count++ } END { print count + 0 }' "$meta" 2>/dev/null) || {
    JG_BACKLOG_TRANSITION_ERROR="unreadable spawn generation in task record $meta"
    return 1
  }
  [ "$count" -ne 0 ] || return 0
  jg_backlog_meta_spawn_gen "$meta" "$state"
}

jg_backlog_row_dispatchable() {
  case "$1" in
    in_flight\ no\ no|queued\ no\ no) return 0 ;;
    *) return 1 ;;
  esac
}

jg_backlog_dispatch_transition() {
  local meta=$1 data=$2 id=$3 state=$4 row row_status
  jg_backlog_record_present "$meta" "task record" "$state" || return 1
  jg_backlog_row_probe "$data" "$id"
  row_status=$?
  if [ "$row_status" -ne 0 ]; then
    if [ "$JG_BACKLOG_ROW_RESULT" = not_found ]; then
      JG_BACKLOG_TRANSITION_ERROR="backlog item $id vanished before dispatch commit"
    else
      JG_BACKLOG_TRANSITION_ERROR=$JG_BACKLOG_ROW_ERROR
    fi
    return "$row_status"
  fi
  row=$JG_BACKLOG_ROW_STATE
  if ! jg_backlog_row_dispatchable "$row"; then
    JG_BACKLOG_TRANSITION_ERROR="backlog item $id is not dispatchable in state $row"
    return 1
  fi
  case "$row" in
    in_flight\ no\ no) jg_backlog_lane_claim "$meta" "$data" "$id" "$state" ;;
    queued\ no\ no) jg_backlog_lane_start "$meta" "$data" "$id" "$state" ;;
  esac
}

jg_backlog_dispatch_rollback() {
  local meta=$1 busy_script=$2 state=$3 id=$4 gen=$5 failed=0
  jg_backlog_record_remove "$meta" "provisional task record" "$state" || failed=1
  if [ -n "$gen" ]; then
    "$busy_script" retire "$state" "$id" --gen "$gen" >/dev/null 2>&1 || failed=1
    if [ -e "$state/$id.busy-state" ] || [ -L "$state/$id.busy-state" ] \
       || [ -e "$state/$id.busy-gen" ] || [ -L "$state/$id.busy-gen" ]; then
      failed=1
    fi
  fi
  if [ "$failed" -ne 0 ]; then
    JG_BACKLOG_TRANSITION_ERROR="failed-dispatch cleanup did not remove both task and busy records for $id"
    return 1
  fi
  return 0
}

jg_backlog_close_transition() {
  local meta=$1 marker=$2 data=$3 id=$4 state=$5
  shift 5
  "${BASH_SOURCE[0]%/*}/jg-machine-shadow.sh" task "$id" "done" || true  # shadow report of the move (jg-machine-shadow.sh)
  [ -z "$meta" ] || jg_backlog_record_remove "$meta" "task record" "$state" || return 1
  if ! jg_backlog_done "$data" "$id" "$@"; then
    # A backlog that never held this row has nothing left to close, which is
    # what a close asks for; a lane dispatched with no row, or a fixture home,
    # reaches teardown exactly like that. Any other failure stays a failure.
    case ${JG_BACKLOG_TRANSITION_ERROR-} in
      *'not found in this backlog'*) JG_BACKLOG_TRANSITION_ERROR= ;;
      *) return 1 ;;
    esac
  fi
  jg_backlog_record_remove "$marker" "pending-close record" "$state"
}

# The captain-held twin of the close transition: same record, same ordering,
# `reopen` with the deliverable recorded instead of `done`.
jg_backlog_retain_transition() {
  local meta=$1 marker=$2 data=$3 id=$4 state=$5
  shift 5
  [ -z "$meta" ] || jg_backlog_record_remove "$meta" "task record" "$state" || return 1
  jg_backlog_retain "$data" "$id" "$@" || return 1
  jg_backlog_record_remove "$marker" "pending-close record" "$state"
}

jg_backlog_atomic_transition() {
  local operation=$1
  shift
  case "$operation" in
    publish) jg_backlog_record_publish "$@" ;;
    remove) jg_backlog_record_remove "$@" ;;
    dispatch) jg_backlog_dispatch_transition "$@" ;;
    handover) jg_backlog_lane_handover "$@" ;;
    rollback) jg_backlog_dispatch_rollback "$@" ;;
    close) jg_backlog_close_transition "$@" ;;
    retain) jg_backlog_retain_transition "$@" ;;
    *) JG_BACKLOG_TRANSITION_ERROR="unknown backlog atomic transition $operation"; return 2 ;;
  esac
}

jg_backlog_close_marker_path() {  # <state-dir> <id>
  printf '%s/%s.backlog-close\n' "$1" "$2"
}

jg_backlog_close_marker_validate() {  # <marker-path> <authorized-data-dir> <expected-id> <state-dir>
  local marker=$1 authorized_data data_resolved expected_id=$3 state=$4
  local id='' data='' marker_spawn_gen='' cleanup_incomplete=0 mode=close line raw_bytes arg_value
  local url_tail url_authority url_path url_host url_port host_rest host_label host_valid
  local percent_tail percent_valid
  local id_count=0 data_count=0 spawn_gen_count=0 cleanup_incomplete_count=0 mode_count=0
  local args=()
  JG_BACKLOG_CLOSE_VALIDATED_ID=
  JG_BACKLOG_CLOSE_VALIDATED_DATA=
  JG_BACKLOG_CLOSE_VALIDATED_SPAWN_GEN=
  JG_BACKLOG_CLOSE_VALIDATED_CLEANUP_INCOMPLETE=0
  JG_BACKLOG_CLOSE_VALIDATED_MODE=close
  JG_BACKLOG_CLOSE_VALIDATED_ARGS=()
  jg_backlog_record_present "$marker" "pending-close record" "$state" || return 1
  raw_bytes=$(jg_backlog_bytes_of_file "$marker" 2>/dev/null) || {
    JG_BACKLOG_TRANSITION_ERROR="unreadable pending-close record $marker"
    return 1
  }
  if ! jg_backlog_control_bytes_valid 1 "$raw_bytes"; then
    JG_BACKLOG_TRANSITION_ERROR="invalid control byte in pending-close record $marker"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      id=*) id=${line#id=}; id_count=$((id_count + 1)) ;;
      data=*) data=${line#data=}; data_count=$((data_count + 1)) ;;
      spawn_gen=*) marker_spawn_gen=${line#spawn_gen=}; spawn_gen_count=$((spawn_gen_count + 1)) ;;
      cleanup_incomplete=*) cleanup_incomplete=${line#cleanup_incomplete=}; cleanup_incomplete_count=$((cleanup_incomplete_count + 1)) ;;
      mode=*) mode=${line#mode=}; mode_count=$((mode_count + 1)) ;;
      arg=*) args+=("${line#arg=}") ;;
      *) JG_BACKLOG_TRANSITION_ERROR="unreadable pending-close record $marker"; return 1 ;;
    esac
  done < "$marker"
  if [ "$mode_count" -gt 1 ]; then
    JG_BACKLOG_TRANSITION_ERROR="unreadable pending-close record $marker"
    return 1
  fi
  case "$mode" in
    close|retain) ;;
    *)
      JG_BACKLOG_TRANSITION_ERROR="invalid transition mode in pending-close record $marker"
      return 1
      ;;
  esac
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*)
      JG_BACKLOG_TRANSITION_ERROR="invalid task identity in pending-close record $marker"
      return 1
      ;;
  esac
  if [ "$id_count" -ne 1 ] || [ "$id" != "$expected_id" ] \
     || [ "$data_count" -ne 1 ] || [ -z "$data" ] \
     || [ "$spawn_gen_count" -ne 1 ]; then
    JG_BACKLOG_TRANSITION_ERROR="unreadable pending-close record $marker"
    return 1
  fi
  case "$marker_spawn_gen" in
    ''|.*|*[!A-Za-z0-9._-]*)
      JG_BACKLOG_TRANSITION_ERROR="invalid spawn generation in pending-close record $marker"
      return 1
      ;;
  esac
  if [ "$cleanup_incomplete_count" -gt 1 ]; then
    JG_BACKLOG_TRANSITION_ERROR="unreadable pending-close record $marker"
    return 1
  fi
  case "$cleanup_incomplete" in
    0|1) ;;
    *)
      JG_BACKLOG_TRANSITION_ERROR="invalid cleanup state in pending-close record $marker"
      return 1
      ;;
  esac
  case "$data" in
    /*) ;;
    *) JG_BACKLOG_TRANSITION_ERROR="invalid data directory in pending-close record $marker"; return 1 ;;
  esac
  case "$data" in
    */../*|*/..)
      JG_BACKLOG_TRANSITION_ERROR="invalid data directory in pending-close record $marker"
      return 1
      ;;
  esac
  authorized_data=$(jg_backlog_data_absolute "$2") || {
    JG_BACKLOG_TRANSITION_ERROR="authorized data directory cannot be resolved: $2"
    return 1
  }
  data_resolved=$(jg_backlog_data_absolute "$data") || {
    JG_BACKLOG_TRANSITION_ERROR="data directory in pending-close record cannot be resolved: $data"
    return 1
  }
  if [ "$data_resolved" != "$authorized_data" ]; then
    JG_BACKLOG_TRANSITION_ERROR="foreign data directory in pending-close record $marker"
    return 1
  fi
  case "${#args[@]}" in
    0) ;;
    2)
      case "${args[0]}" in
        --note) case ${args[1]} in local%20main|local-trunk) true ;; *) false ;; esac ;;
        --pr)
          arg_value=${args[1]}
          [ "${#arg_value}" -le 2048 ] \
            && case "$arg_value" in https://*) true ;; *) false ;; esac \
            && case "$arg_value" in
              *[[:space:]]*|*[!A-Za-z0-9:/?\&=._#%+~@-]*) false ;;
              *) true ;;
            esac \
            && {
              url_tail=${arg_value#https://}
              url_authority=${url_tail%%/*}
              url_path=${url_tail#*/}
              url_host=$url_authority
              url_port=
              case "$url_authority" in
                *:*) url_host=${url_authority%%:*}; url_port=${url_authority#*:} ;;
              esac
              [ "$url_path" != "$url_tail" ] \
                && case "$url_host" in
                  ''|[-.]*|*[-.]|*..*|*[!A-Za-z0-9.-]*) false ;;
                  *[A-Za-z0-9]*) true ;;
                  *) false ;;
                esac \
                && {
                  host_rest=$url_host
                  host_valid=1
                  while :; do
                    host_label=${host_rest%%.*}
                    case "$host_label" in ''|-*|*-) host_valid=0; break ;; esac
                    [ "$host_rest" = "$host_label" ] && break
                    host_rest=${host_rest#*.}
                  done
                  [ "$host_valid" = 1 ]
                } \
                && case "$url_authority" in
                  *:*) case "$url_port" in ''|*[!0-9]*|??????*) false ;; *) true ;; esac ;;
                  *) true ;;
                esac \
                && case "$url_path" in *[A-Za-z0-9]*) true ;; *) false ;; esac \
                && {
                  percent_tail=$url_path
                  percent_valid=1
                  while case "$percent_tail" in *%*) true ;; *) false ;; esac; do
                    percent_tail=${percent_tail#*%}
                    case "$percent_tail" in
                      [0-9A-Fa-f][0-9A-Fa-f]*) percent_tail=${percent_tail#??} ;;
                      *) percent_valid=0; break ;;
                    esac
                  done
                  [ "$percent_valid" = 1 ]
                }
            }
          ;;
        --report)
          arg_value=${args[1]}
          [ "${#arg_value}" -le 4096 ] \
            && [ -n "${arg_value// /}" ] \
            && case "$arg_value" in .|..|-*|/*|../*|*/../*|*/..) false ;; *) true ;; esac
          ;;
        *) false ;;
      esac || { JG_BACKLOG_TRANSITION_ERROR="invalid pending-close arguments in $marker"; return 1; }
      ;;
    *) JG_BACKLOG_TRANSITION_ERROR="invalid pending-close arguments in $marker"; return 1 ;;
  esac
  JG_BACKLOG_CLOSE_VALIDATED_ID=$id
  JG_BACKLOG_CLOSE_VALIDATED_DATA=$data_resolved
  JG_BACKLOG_CLOSE_VALIDATED_SPAWN_GEN=$marker_spawn_gen
  JG_BACKLOG_CLOSE_VALIDATED_CLEANUP_INCOMPLETE=$cleanup_incomplete
  JG_BACKLOG_CLOSE_VALIDATED_MODE=$mode
  JG_BACKLOG_CLOSE_VALIDATED_ARGS=("${args[@]+"${args[@]}"}")
}

# A leading `--retain` flag records the captain-held transition (`mode=retain`)
# instead of a close; the remaining flags are the same completion links either
# transition records.
jg_backlog_close_marker_stage() {  # <temporary-path> <id> <data-dir> <spawn-gen> <state-dir> <cleanup-incomplete: 0|1> [--retain] [flag...]
  local tmp=$1 id=$2 data spawn_gen=$4 state=$5 cleanup_incomplete=$6 arg previous_arg=''
  local mode=close serialized_args=()
  data=$(jg_backlog_data_absolute "$3") || {
    JG_BACKLOG_TRANSITION_ERROR="data directory cannot be resolved: $3"
    return 1
  }
  jg_backlog_record_parent_authorized "$tmp" "pending-close staging path" "$state" || return 1
  if [ -e "$tmp" ] || [ -L "$tmp" ]; then
    JG_BACKLOG_TRANSITION_ERROR="unsafe pending-close staging path $tmp"
    return 1
  fi
  case "$cleanup_incomplete" in
    0|1) ;;
    *) JG_BACKLOG_TRANSITION_ERROR="invalid pending-close cleanup state"; return 1 ;;
  esac
  shift 6
  if [ "${1:-}" = --retain ]; then
    mode=retain
    shift
  fi
  for arg in "$@"; do
    if [ "$previous_arg" = --note ] && [ "$arg" = "local main" ]; then
      serialized_args+=("local%20main")
    else
      serialized_args+=("$arg")
    fi
    previous_arg=$arg
  done
  {
    printf 'id=%s\n' "$id"
    printf 'data=%s\n' "$data"
    printf 'spawn_gen=%s\n' "$spawn_gen"
    printf 'cleanup_incomplete=%s\n' "$cleanup_incomplete"
    [ "$mode" = close ] || printf 'mode=%s\n' "$mode"
    for arg in "${serialized_args[@]+"${serialized_args[@]}"}"; do
      printf 'arg=%s\n' "$arg"
    done
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  jg_backlog_close_marker_validate "$tmp" "$data" "$id" "$state" \
    || { rm -f "$tmp"; return 1; }
}

# Record the exact close a teardown is about to perform.
jg_backlog_close_marker_write() {  # <state-dir> <id> <data-dir> <spawn-gen> [flag...]
  local state=$1 id=$2 data=$3 spawn_gen=$4 marker tmp
  jg_backlog_directory_present "$state" "state directory" || return 1
  shift 4
  marker=$(jg_backlog_close_marker_path "$state" "$id") || return 1
  tmp="$state/.$id.backlog-close.${BASHPID:-$$}"
  jg_backlog_close_marker_stage "$tmp" "$id" "$data" "$spawn_gen" "$state" 0 "$@" || return 1
  jg_backlog_atomic_transition publish "$tmp" "$marker" "pending-close record" "$state" \
    || { rm -f "$tmp"; return 1; }
}

jg_backlog_close_marker_mark_cleanup_incomplete() {  # <state-dir> <marker-path> <id> <data-dir> <spawn-gen> [flag...]
  local state=$1 marker=$2 id=$3 data=$4 spawn_gen=$5 tmp
  shift 5
  tmp="$state/.$id.backlog-close.${BASHPID:-$$}"
  jg_backlog_close_marker_stage "$tmp" "$id" "$data" "$spawn_gen" "$state" 1 "$@" || return 1
  jg_backlog_atomic_transition publish "$tmp" "$marker" "pending-close record" "$state" \
    || { rm -f "$tmp"; return 1; }
}

jg_backlog_close_marker_remove() {  # <marker-path> <state-dir>
  jg_backlog_atomic_transition remove "$1" "pending-close record" "$2"
}

jg_backlog_close_marker_clear() {  # <state-dir> <id>
  local marker
  marker=$(jg_backlog_close_marker_path "$1" "$2") || return 1
  jg_backlog_close_marker_remove "$marker" "$1"
}

# Replay one recorded close or retention. Returns 0 when the row is closed (or
# retained), the marker is stale, or an answer already closed a retained row,
# and 1 when marker validation or recovery fails. Validation completes before
# any meta or backlog mutation.
jg_backlog_close_marker_replay() {  # <state-dir> <marker-path> <authorized-data-dir>
  local state=$1 marker=$2 marker_name expected_id
  local id data marker_spawn_gen meta meta_spawn_gen row_state cleanup_incomplete mode
  local args=() mode_flags=()
  JG_BACKLOG_CLOSE_REPLAY_RESULT=noop
  jg_backlog_directory_present "$state" "state directory" || return 1
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  marker_name=${marker##*/}
  case "$marker_name" in
    *.backlog-close) expected_id=${marker_name%.backlog-close} ;;
    *) JG_BACKLOG_TRANSITION_ERROR="invalid pending-close record name $marker"; return 1 ;;
  esac
  jg_backlog_close_marker_validate "$marker" "$3" "$expected_id" "$state" || return 1
  id=$JG_BACKLOG_CLOSE_VALIDATED_ID
  data=$JG_BACKLOG_CLOSE_VALIDATED_DATA
  marker_spawn_gen=$JG_BACKLOG_CLOSE_VALIDATED_SPAWN_GEN
  cleanup_incomplete=$JG_BACKLOG_CLOSE_VALIDATED_CLEANUP_INCOMPLETE
  mode=$JG_BACKLOG_CLOSE_VALIDATED_MODE
  [ "$mode" = close ] || mode_flags=(--retain)
  args=("${JG_BACKLOG_CLOSE_VALIDATED_ARGS[@]+"${JG_BACKLOG_CLOSE_VALIDATED_ARGS[@]}"}")
  if [ "${args[0]-}" = --note ] && [ "${args[1]-}" = local%20main ]; then
    args[1]="local main"
  fi
  meta="$state/$id.meta"
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    if ! jg_backlog_record_present "$meta" "task record" "$state"; then
      JG_BACKLOG_TRANSITION_ERROR="unsafe interrupted task record at $meta"
      return 1
    fi
    jg_backlog_meta_spawn_gen "$meta" "$state" || return 1
    meta_spawn_gen=$JG_BACKLOG_META_SPAWN_GEN
    if [ "$meta_spawn_gen" != "$marker_spawn_gen" ]; then
      jg_backlog_close_marker_remove "$marker" "$state" || return 1
      JG_BACKLOG_CLOSE_REPLAY_RESULT=stale
      return 0
    fi
    if [ -e "$state/$id.scratch" ] || [ -L "$state/$id.scratch" ] || [ -d "$data/$id" ]; then
      JG_BACKLOG_TRANSITION_ERROR="task scratch or retained-data process cleanup remains outstanding for $id; rerun teardown before replaying its backlog close"
      return 1
    fi
    jg_backlog_close_marker_mark_cleanup_incomplete "$state" "$marker" "$id" "$data" \
      "$marker_spawn_gen" "${mode_flags[@]+"${mode_flags[@]}"}" "${args[@]+"${args[@]}"}" \
      || return 1
    cleanup_incomplete=1
    jg_backlog_atomic_transition remove "$meta" "the interrupted task record" "$state" \
      || return 1
  fi
  if jg_backlog_row_probe "$data" "$id"; then
    row_state=$JG_BACKLOG_ROW_STATE
    if [ "${row_state%% *}" != "done" ] && [ "$JG_BACKLOG_ROW_HOLD_KIND" = captain ]; then
      mode=retain
    fi
  else
    if [ "$JG_BACKLOG_ROW_RESULT" != not_found ]; then
      JG_BACKLOG_TRANSITION_ERROR=$JG_BACKLOG_ROW_ERROR
      return 1
    fi
    row_state=
  fi
  case "$row_state" in
    done\ *)
      if [ "$mode" = retain ]; then
        # The captain's answer closed the row before this replay; the retained
        # transition owes it nothing more than retiring the record.
        jg_backlog_close_marker_remove "$marker" "$state" || return 1
        JG_BACKLOG_CLOSE_REPLAY_RESULT=answered
        return 0
      fi
      if jg_backlog_atomic_transition close '' "$marker" "$data" "$id" "$state" \
          "${args[@]+"${args[@]}"}"; then
        if [ "$cleanup_incomplete" = 1 ]; then
          JG_BACKLOG_CLOSE_REPLAY_RESULT=closed_incomplete
        else
          JG_BACKLOG_CLOSE_REPLAY_RESULT=closed
        fi
        return 0
      fi
      return 1
      ;;
    '')
      jg_backlog_close_marker_remove "$marker" "$state" || return 1
      JG_BACKLOG_CLOSE_REPLAY_RESULT=stale
      return 0
      ;;
  esac
  if jg_backlog_atomic_transition "$mode" '' "$marker" "$data" "$id" "$state" \
      "${args[@]+"${args[@]}"}"; then
    if [ "$mode" = retain ]; then
      if [ "$cleanup_incomplete" = 1 ]; then
        JG_BACKLOG_CLOSE_REPLAY_RESULT=retained_incomplete
      else
        JG_BACKLOG_CLOSE_REPLAY_RESULT=retained
      fi
    elif [ "$cleanup_incomplete" = 1 ]; then
      JG_BACKLOG_CLOSE_REPLAY_RESULT=closed_incomplete
    else
      JG_BACKLOG_CLOSE_REPLAY_RESULT=closed
    fi
    return 0
  fi
  return 1
}
