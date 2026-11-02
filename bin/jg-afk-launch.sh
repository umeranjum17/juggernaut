#!/usr/bin/env bash
# jg-afk-launch.sh - the single owner of away-mode ENTRY and EXIT: the
# same-turn entry that writes the away-posture record through
# bin/jg-afk-contract.sh, and the away-mode daemon TERMINAL lifecycle where a
# daemon still runs: launch it in a NON-VISIBLE tracked terminal per backend,
# record its exact id, tear it down by that exact id, and reconcile a leaked one
# after a crash.
#
# ENTRY (the posture record). `/watchover [words]` is itself the captain's go, because
# the captain who typed it may not look at the screen again: `enter` records the
# away words verbatim straight into state/.afk-contract in the same turn, with no
# separate confirmation step, then prints the entry announcement (hold-for-return
# only: no phone channel exists; a quiet entry's says nothing is held) and the
# read-back, which is informational and never waits for a go
# (bin/jg-afk-contract.sh owns the record schema; the words are the whole
# mandate and no script parses them). The record is the posture in every
# harness.
# On Pi and pi-signed the entry ENDS there: the away daemon is no longer launched
# on Pi, the ordinary supervision session keeps running in both postures, and
# `start` refuses on those harnesses. The same holds for away mode (not quiet
# mode) on a claude, cursor, opencode, omp, grok, or codex primary whose home
# runs the supervision host (jg_supervision_host_enabled: by default on
# Claude, by config/supervision-host elsewhere), where the host runs the away
# session; `enter` there adds one line when the host has no
# engine, because every away wake then reaches main. Every other harness still
# runs the daemon for now, so `start` and `start-native` require the record
# `enter` wrote before they launch the daemon.
# QUIET MODE on a home that runs the supervision host needs nothing
# where the attended host runs (docs/supervision-host.md "Quiet mode"): its
# primary is attended-ready (jg_supervision_host_attended_ready: engine, tools,
# and a verified dialog-mirror writer), the main session can be identified,
# and the dialog mirror passes the feed's validation (bin/jg-host-mirror.sh
# check), because that host already keeps the wakes it can take off a present
# captain's main. `quiet-check` then says so, or, while the host's
# broken-session latch holds, that the session is paused and when it retries;
# either way a quiet `enter` refuses (exit 3) before writing anything, so quiet
# mode never leaves a record that would park a present captain's main. While
# an away record (one without the quiet mode a quiet entry records) is live on
# that home, whatever state/.afk says, `quiet-check` (exit 2) and a quiet
# `enter` (exit 3) refuse and name it: the captain's return
# (bin/jg-afk-return.sh and its catch-up gate) comes first. Where the attended
# host lacks one of those parts, `quiet-check` names it and quiet mode enters
# through the daemon as it does without the host. A quiet `enter` records its
# mode, so `start` and `start-native` launch the quiet daemon without
# JG_AFK_MODE; a running quiet daemon is refreshed by a later `/radio-silence` and runs
# until `/radio-silence off`. A quiet `start` or `start-native` that fails while no
# daemon runs ends quiet mode as `stop` does, so no quiet record outlives its
# daemon to park a present captain's main.
# `stop` (the return, driven by bin/jg-afk-return.sh) shuts the daemon down,
# clears state/.afk last, and archives the record under state/afk-contracts/.
#
# Why the terminal lifecycle exists (docs/herdr-backend.md "Away-mode daemon terminal launch"):
# bin/jg-afk-start.sh execs the supervise daemon in the FOREGROUND of whatever
# terminal it is already in. Harnesses with a native in-pane tracked-background
# tool (claude, grok) run it there directly and it is fine. A harness with NO
# native background mechanism (pi) has to manufacture a terminal, and doing that
# by SPLITTING the captain's active pane visibly shrinks it - the regression this
# script fixes. Instead this creates a non-visible tracked terminal (a herdr tab/
# workspace with --no-focus, or a detached tmux session) that never touches the
# captain's active tab, and NEVER uses shell `&` (which herdr/codex can reap).
#
# Correct supervisor targeting: the daemon finds the captain pane to inject into
# from its OWN inherited env (discover_supervisor_target). Running it in a
# separate terminal would make it discover its OWN pane, so this captures the
# captain pane FIRST (from the pane this script runs in) and passes it in as
# JG_SUPERVISOR_TARGET/JG_SUPERVISOR_BACKEND explicitly.
#
# Usage:
#   jg-afk-launch.sh enter [--words-file <path> | --words <text>]
#                          [--expected-return <UTC ISO 8601>] [--spend <n>]
#                              Write the away-posture record now, with no
#                              separate confirmation, then print the entry
#                              announcement and the read-back. With no words
#                              while away it is a refresh; new words replace
#                              the mandate. On Pi this is the whole entry.
#   jg-afk-launch.sh start     Capture the captain pane, then (unless the daemon
#                              is already running) launch the daemon in a fresh
#                              non-visible terminal for the detected backend and
#                              record it. Idempotent: an already-running daemon
#                              just refreshes state/.afk; a recorded-but-dead
#                              terminal is reconciled (closed by id) first.
#   jg-afk-launch.sh start-native
#                              Prepare lifecycle state for a harness-native
#                              background job and record that no terminal exists.
#   jg-afk-launch.sh stop      Correct-ordered exit: SIGTERM the daemon so its
#                              cleanup flushes WHILE state/.afk is still present,
#                              wait for it, close a recorded non-native terminal
#                              by exact id, clear state/.afk, then archive the
#                              record last. A Pi or native entry that never
#                              launched a daemon reports that none was running.
#   jg-afk-launch.sh reconcile Close a recorded-but-dead daemon terminal by exact
#                              id and drop the record (recovery after a crash).
#   jg-afk-launch.sh quiet-check
#                              Whether /radio-silence needs anything here (QUIET MODE
#                              above): exit 0 with one line when it needs
#                              nothing; exit 1 when quiet mode enters through
#                              `enter` and the daemon, with one line naming why
#                              only on a home that runs the host; exit 2 with one
#                              line naming a live away record on that home.
#
# Supported backends: herdr, tmux. Others (zellij, orca, cmux) have no verified
# non-visible-launch primitive here yet and refuse loudly.
#
# Test seam: JG_AFK_LAUNCH_ENTRY overrides the command run in the created
# terminal (default bin/jg-afk-start.sh), so a topology test can run a harmless
# placeholder instead of a real daemon. JG_SUPERVISOR_TARGET/JG_SUPERVISOR_BACKEND
# override the captured captain pane/backend (an isolated lab pane in tests).
# JG_AFK_MODE (away|quiet, default away) declares which mode an `enter` writes;
# with it unset, a daemon start/refresh uses the record's mode.
# JG_TEST_HARNESS pins the primary harness this launch path judges, through
# jg_supervision_host_primary (bin/jg-supervision-engine-lib.sh owns the seam).
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -u

JG_AFK_LAUNCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$JG_AFK_LAUNCH_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
case "$JG_HOME" in
  /*) ;;
  *)
    JG_AFK_LAUNCH_HOME_INPUT=$JG_HOME
    JG_HOME=$(CDPATH='' cd -- "$JG_AFK_LAUNCH_HOME_INPUT" 2>/dev/null && pwd -P) || {
      echo "error: JG_HOME directory cannot be resolved: $JG_AFK_LAUNCH_HOME_INPUT" >&2
      exit 1
    }
    ;;
esac
if [ -n "${JG_STATE_OVERRIDE:-}" ]; then
  case "$JG_STATE_OVERRIDE" in
    /*) ;;
    *)
      JG_AFK_LAUNCH_STATE_INPUT=$JG_STATE_OVERRIDE
      JG_STATE_OVERRIDE=$(CDPATH='' cd -- "$JG_AFK_LAUNCH_STATE_INPUT" 2>/dev/null && pwd -P) || {
        echo "error: JG_STATE_OVERRIDE directory cannot be resolved: $JG_AFK_LAUNCH_STATE_INPUT" >&2
        exit 1
      }
      ;;
  esac
fi
JG_AFK_LAUNCH_STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
JG_AFK_LAUNCH_RECORD="$JG_AFK_LAUNCH_STATE/.afk-daemon-terminal"
JG_AFK_LAUNCH_LOCK="$JG_AFK_LAUNCH_STATE/.afk-launch.lock"
JG_AFK_LAUNCH_WS_LABEL="juggernaut-afk-daemon"

# shellcheck source=bin/jg-backend.sh
. "$JG_AFK_LAUNCH_DIR/jg-backend.sh"
# shellcheck source=bin/jg-supervisor-target-lib.sh
. "$JG_AFK_LAUNCH_DIR/jg-supervisor-target-lib.sh"
# jg-afk-start.sh provides the daemon-lock liveness helpers and
# jg_afk_clear_stale_artifacts; it is sourceable (BASH_SOURCE guard) and its
# main does not run on source. It sets `set -eu`, so turn errexit back off for
# this script's best-effort flow immediately after.
# shellcheck source=bin/jg-afk-start.sh
. "$JG_AFK_LAUNCH_DIR/jg-afk-start.sh"
set +e
# The away-posture record owner; sourced for its path helpers, driven as a
# command for every record mutation so its output reaches the captain.
# shellcheck source=bin/jg-afk-contract.sh
. "$JG_AFK_LAUNCH_DIR/jg-afk-contract.sh"
JG_AFK_CONTRACT_CMD="$JG_AFK_LAUNCH_DIR/jg-afk-contract.sh"
# The supervision host's home gate and attended readiness check.
# shellcheck source=bin/jg-supervision-engine-lib.sh
. "$JG_AFK_LAUNCH_DIR/jg-supervision-engine-lib.sh"

jg_afk_launch_log() { printf 'jg-afk-launch: %s\n' "$*" >&2; }

jg_afk_launch_lock_owned() {
  local pid expected actual
  [ -d "$JG_AFK_LAUNCH_LOCK" ] || return 1
  pid=$(cat "$JG_AFK_LAUNCH_LOCK/pid" 2>/dev/null) || return 1
  expected=$(cat "$JG_AFK_LAUNCH_LOCK/pid-identity" 2>/dev/null) || return 1
  actual=$(jg_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$expected" ] && [ "$actual" = "$expected" ]
}

jg_afk_launch_lock_acquire() {
  local attempt=0 incomplete=0 identity
  mkdir -p "$JG_AFK_LAUNCH_STATE" || return 1
  while [ "$attempt" -lt 200 ]; do
    attempt=$((attempt + 1))
    if mkdir "$JG_AFK_LAUNCH_LOCK" 2>/dev/null; then
      if ! printf '%s' "$$" > "$JG_AFK_LAUNCH_LOCK/pid"; then
        rm -rf "$JG_AFK_LAUNCH_LOCK"
        return 1
      fi
      identity=$(jg_pid_identity "$$" 2>/dev/null) || {
        rm -rf "$JG_AFK_LAUNCH_LOCK"
        return 1
      }
      if [ -z "$identity" ] || ! printf '%s' "$identity" > "$JG_AFK_LAUNCH_LOCK/pid-identity"; then
        rm -rf "$JG_AFK_LAUNCH_LOCK"
        return 1
      fi
      return 0
    fi
    if [ ! -s "$JG_AFK_LAUNCH_LOCK/pid" ] || [ ! -s "$JG_AFK_LAUNCH_LOCK/pid-identity" ]; then
      incomplete=$((incomplete + 1))
      if [ "$incomplete" -lt 20 ]; then
        sleep 0.05
        continue
      fi
    else
      incomplete=0
    fi
    if ! jg_afk_launch_lock_owned; then
      rm -rf "$JG_AFK_LAUNCH_LOCK" 2>/dev/null || return 1
      incomplete=0
      continue
    fi
    sleep 0.05
  done
  jg_afk_launch_log "timed out waiting for launcher lock"
  return 1
}

jg_afk_launch_lock_release() {
  local pid
  pid=$(cat "$JG_AFK_LAUNCH_LOCK/pid" 2>/dev/null || true)
  [ "$pid" = "$$" ] || return 0
  rm -rf "$JG_AFK_LAUNCH_LOCK"
}

jg_afk_launch_usage() {
  sed -n '/^# Usage:/,/^# Supported backends:/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

jg_afk_launch_primary_harness() {
  jg_supervision_host_primary
}

# The primary harnesses whose arm owner runs the supervision host when the
# home runs it (docs/supervision-host.md).
jg_afk_launch_host_primary() {  # <harness>
  case "$1" in
    claude|cursor|opencode|omp|grok|codex) return 0 ;;
  esac
  return 1
}

# True when the posture record is a quiet entry's (bin/jg-afk-contract.sh mode).
jg_afk_launch_record_quiet() {
  [ "$(jg_afk_contract_mode "$JG_AFK_LAUNCH_STATE")" = quiet ]
}

# An explicit request takes precedence; otherwise the record owns the mode
# for both a new daemon and a refresh of an existing one.
jg_afk_launch_requested_mode() {
  if [ -n "${JG_AFK_MODE:-}" ]; then
    printf '%s' "$JG_AFK_MODE"
  else
    jg_afk_contract_mode "$JG_AFK_LAUNCH_STATE"
  fi
}

# Whether /radio-silence needs anything here (the header's QUIET MODE): 0 when it needs
# nothing; 2 while an away record is live on a home that runs the host;
# otherwise 1, with JG_AFK_LAUNCH_QUIET_WHY naming what the attended host
# lacks on a home that runs it, or empty where quiet mode is the daemon's as
# it is without the host (no host, another primary, or quiet mode already
# entered).
jg_afk_launch_quiet_needs_nothing() {
  local harness config
  JG_AFK_LAUNCH_QUIET_WHY=
  harness=$(jg_afk_launch_primary_harness)
  jg_afk_launch_host_primary "$harness" || return 1
  config=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
  jg_supervision_host_enabled "$config" "$harness" || return 1
  if jg_afk_contract_present "$JG_AFK_LAUNCH_STATE"; then
    jg_afk_launch_record_quiet || return 2
    return 1
  fi
  [ ! -e "$JG_AFK_LAUNCH_STATE/.afk" ] || return 1
  if ! jg_supervision_host_attended_ready "$config" "$harness"; then
    JG_AFK_LAUNCH_QUIET_WHY="$JG_SUPERVISION_HOST_UNREADY${JG_SUPERVISION_ENGINE_PROBLEM:+: $JG_SUPERVISION_ENGINE_PROBLEM}"
  elif ! jg_supervision_host_main_key "$JG_AFK_LAUNCH_STATE" >/dev/null; then
    JG_AFK_LAUNCH_QUIET_WHY="the main session could not be identified"
  elif ! JG_STATE_OVERRIDE="$JG_AFK_LAUNCH_STATE" "$JG_AFK_LAUNCH_DIR/jg-host-mirror.sh" check; then
    JG_AFK_LAUNCH_QUIET_WHY="the dialog mirror is missing or could not be read"
  fi
  [ -z "$JG_AFK_LAUNCH_QUIET_WHY" ]
}

jg_afk_launch_quiet_check() {
  local rc retry
  jg_afk_launch_quiet_needs_nothing
  rc=$?
  if [ "$rc" -eq 2 ]; then
    printf 'Quiet mode starts nothing on this home while its away record (state/.afk-contract) is live: the captain has returned, so run the /watchover return (bin/jg-afk-return.sh), pass its catch-up gate, then run quiet-check again.\n'
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    [ -z "$JG_AFK_LAUNCH_QUIET_WHY" ] \
      || printf 'Quiet mode is not already the ordinary posture on this home, because %s, so every attended wake reaches this conversation; quiet mode enters through the quiet daemon instead.\n' "$JG_AFK_LAUNCH_QUIET_WHY"
    return 1
  fi
  if retry=$(jg_supervision_host_paused_until "$JG_AFK_LAUNCH_STATE"); then
    if [ "$(date +%s)" -lt "$retry" ]; then
      retry="its next retry is due at $(jg_supervision_host_clock "$retry")"
    else
      retry="its next wake retries it"
    fi
    printf 'Quiet mode starts nothing on this home, but its supervision session is paused after repeated engine errors: routine wakes reach this conversation until it recovers, and %s.\n' "$retry"
    return 0
  fi
  printf 'Quiet mode needs nothing on this home: the ordinary supervision session already handles the wakes it can while the captain is present, never opens a turn here for a routine outcome, and hands this conversation only what needs it; no daemon and no away record are used.\n'
}

# The away daemon is no longer launched on Pi, nor for away mode on a primary
# whose home runs the supervision host (jg_supervision_host_enabled,
# docs/supervision-host.md): the posture record is the whole entry there and
# the ordinary supervision session runs in both postures. Quiet mode runs the
# daemon on that home only where a quiet `enter` found the attended host
# unready (the header's QUIET MODE), so a quiet entry or a refresh of a running
# quiet daemon is allowed.
jg_afk_launch_daemon_allowed() {
  local harness mode
  harness=$(jg_afk_launch_primary_harness)
  case "$harness" in
    pi|pi-signed)
      jg_afk_launch_log "the away daemon is no longer launched on $harness; the away-posture record is the posture there (run bin/jg-afk-launch.sh enter and stop)"
      return 1 ;;
  esac
  jg_afk_launch_host_primary "$harness" || return 0
  jg_supervision_host_enabled "${JG_CONFIG_OVERRIDE:-$JG_HOME/config}" "$harness" || return 0
  mode=$(jg_afk_launch_requested_mode)
  if [ -z "$mode" ] && [ -f "$JG_AFK_LAUNCH_STATE/.afk" ]; then
    mode=$(head -n 1 "$JG_AFK_LAUNCH_STATE/.afk" 2>/dev/null || true)
  fi
  [ "$mode" != quiet ] || return 0
  jg_afk_launch_log "the away daemon is not launched on this $harness home, which runs the supervision host (docs/supervision-host.md); the away-posture record is the posture here (run bin/jg-afk-launch.sh enter and stop)"
  return 1
}

# One line for the entry when this home runs the supervision host but the host
# has no engine (bin/jg-supervision-engine-lib.sh owns the home gate), so
# the away posture would hand every wake to main.
jg_afk_launch_host_engine_note() {
  local harness config
  [ "${JG_AFK_MODE:-}" != quiet ] || return 0
  config=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
  harness=$(jg_afk_launch_primary_harness)
  jg_afk_launch_host_primary "$harness" || return 0
  jg_supervision_host_config "$config" "$harness" || return 0
  [ -z "$JG_SUPERVISION_ENGINE" ] || return 0
  printf 'Supervision host: no engine runs the away session on this home (%s), so every away wake reaches this conversation; name a verified engine in config/supervision-host (for example "claude").\n' \
    "$JG_SUPERVISION_ENGINE_PROBLEM"
}

jg_afk_launch_catchup_pending() {
  if [ -e "$JG_AFK_LAUNCH_STATE/.afk-return-catchup" ]; then
    jg_afk_launch_log "return catch-up is still pending; run bin/jg-afk-return.sh check before re-entering away mode"
    return 0
  fi
  return 1
}

jg_afk_launch_record_require() {
  local record
  record=$(jg_afk_contract_path "$JG_AFK_LAUNCH_STATE")
  if ! jg_afk_contract_present "$JG_AFK_LAUNCH_STATE"; then
    jg_afk_launch_log "an away-posture record is required; run enter before starting the daemon"
    return 1
  fi
  jg_afk_contract_validate "$record" || {
    jg_afk_launch_log "the away-posture record is unreadable; run enter before starting the daemon"
    return 1
  }
}

jg_afk_launch_enter() {
  jg_afk_launch_catchup_pending && return 1
  if [ "${JG_AFK_MODE:-}" = quiet ]; then
    jg_afk_launch_quiet_needs_nothing
    case $? in
      0)
        jg_afk_launch_log "quiet mode writes no away-posture record on this home, whose attended supervision host already is quiet mode; run bin/jg-afk-launch.sh quiet-check"
        return 3 ;;
      2)
        jg_afk_launch_log "quiet mode refuses while this home's away record (state/.afk-contract) is live; run the /watchover return (bin/jg-afk-return.sh) and pass its catch-up gate, then run bin/jg-afk-launch.sh quiet-check"
        return 3 ;;
    esac
  fi
  "$JG_AFK_CONTRACT_CMD" enter "$@" || return
  jg_afk_launch_host_engine_note
}

# The command run inside the created terminal. Real launch runs the shared
# daemon entry; a test overrides it with a harmless placeholder.
jg_afk_launch_entry_cmd() {
  printf '%s' "${JG_AFK_LAUNCH_ENTRY:-$JG_ROOT/bin/jg-afk-start.sh}"
}

# The shell command a created daemon terminal runs. The terminal is not in the
# captain's process tree, so the daemon cannot detect the captain's harness
# itself; the launcher names it here (bin/jg-supervise-daemon.sh
# jg_daemon_primary_harness).
jg_afk_launch_daemon_cmd() {  # <captain-target> <captain-backend>
  printf 'exec env JG_HOME=%q JG_SUPERVISOR_TARGET=%q JG_SUPERVISOR_BACKEND=%q JG_DAEMON_PRIMARY_HARNESS=%q %q' \
    "$JG_HOME" "$1" "$2" "$(jg_afk_launch_primary_harness)" "$(jg_afk_launch_entry_cmd)"
}

jg_afk_launch_record_write() {  # <backend> <target> <extra>
  local pending
  mkdir -p "$JG_AFK_LAUNCH_STATE" || return 1
  pending=$(mktemp "$JG_AFK_LAUNCH_STATE/.afk-daemon-terminal.pending.XXXXXX") || return 1
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$JG_AFK_LAUNCH_RECORD" || { rm -f "$pending"; return 1; }
}

jg_afk_launch_flag_write() {
  # Use the explicit request or the record's mode, so /watchover over a quiet
  # record switches a running daemon's flag to away on refresh.
  jg_afk_flag_write "$JG_AFK_LAUNCH_STATE" "$(jg_afk_launch_requested_mode)"
}

# Read the recorded terminal into JG_AFK_REC_BACKEND/JG_AFK_REC_TARGET. The third
# field (a herdr workspace id, kept for the record's own documentation) is not
# needed to close by id, so it is discarded. Returns 1 when no record exists.
jg_afk_launch_record_read() {
  local extra record
  JG_AFK_REC_BACKEND=""; JG_AFK_REC_TARGET=""; extra=""
  [ -f "$JG_AFK_LAUNCH_RECORD" ] || return 1
  record=$(cat "$JG_AFK_LAUNCH_RECORD" 2>/dev/null) || record=""
  IFS=$'\t' read -r JG_AFK_REC_BACKEND JG_AFK_REC_TARGET extra \
    < "$JG_AFK_LAUNCH_RECORD" || true
  if ! printf '%s\n' "$record" | awk -F '\t' 'NF != 3 { bad=1 } END { exit !(NR == 1 && !bad) }' \
    || [ -z "$JG_AFK_REC_BACKEND" ] || [ -z "$JG_AFK_REC_TARGET" ]; then
    jg_afk_launch_log "daemon terminal record is malformed; refusing to act on it"
    return 2
  fi
  case "$JG_AFK_REC_BACKEND" in
    herdr) [ -n "$extra" ] ;;
    tmux) : ;;
    none) [ "$JG_AFK_REC_TARGET" = - ] && [ "$extra" = native ] ;;
    *) return 2 ;;
  esac || { jg_afk_launch_log "daemon terminal record is malformed; refusing to act on it"; return 2; }
}

jg_afk_launch_record_validate_if_present() {
  local result
  jg_afk_launch_record_read
  result=$?
  [ "$result" -ne 2 ]
}

# Close a recorded terminal by EXACT id (never a broad sweep). The
# recorded workspace id (herdr) needs no separate close: closing the pane takes
# its single-tab dedicated workspace with it.
jg_afk_launch_close_terminal() {  # <backend> <target>
  local backend=$1 target=$2
  case "$backend" in
    herdr)
      jg_backend_source herdr || return 1
      local session=${target%%:*} pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      jg_backend_herdr_cli "$session" pane close "$pane" >/dev/null 2>&1
      ;;
    tmux)
      # target is the dedicated daemon session name - kill exactly it.
      tmux kill-session -t "$target" 2>/dev/null
      ;;
    none)
      return 0
      ;;
    *)
      jg_afk_launch_log "cannot close unknown recorded backend '$backend'"
      return 1
      ;;
  esac
}

jg_afk_launch_terminal_absent() {  # <backend> <target>
  local backend=$1 target=$2 session pane out result code
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      out=$(jg_backend_herdr_cli "$session" pane get "$pane" 2>&1)
      result=$?
      [ "$result" -ne 0 ] || return 1
      code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null) || return 1
      [ "$code" = pane_not_found ]
      ;;
    tmux)
      out=$(tmux has-session -t "$target" 2>&1)
      result=$?
      [ "$result" -eq 1 ] || return 1
      printf '%s' "$out" | grep -Eq "can't find session"
      ;;
    none)
      return 0
      ;;
    *) return 1 ;;
  esac
}

jg_afk_launch_close_recorded() {
  local close_result=0
  jg_afk_launch_close_terminal "$JG_AFK_REC_BACKEND" "$JG_AFK_REC_TARGET" || close_result=$?
  if jg_afk_launch_terminal_absent "$JG_AFK_REC_BACKEND" "$JG_AFK_REC_TARGET"; then
    rm -f "$JG_AFK_LAUNCH_RECORD" || return 1
    [ "$close_result" -eq 0 ] || jg_afk_launch_log "terminal close command failed, but exact absence was confirmed"
    return 0
  fi
  jg_afk_launch_log "recorded terminal teardown is unconfirmed; preserving exact id"
  return 1
}

jg_afk_launch_terminal_alive() {  # <backend> <target>
  local backend=$1 target=$2 session pane
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      jg_backend_herdr_cli "$session" pane get "$pane" >/dev/null 2>&1
      ;;
    tmux)
      tmux has-session -t "$target" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

jg_afk_launch_wait_ready() {  # <backend> <target>
  local backend=$1 target=$2 attempt=0
  if [ -n "${JG_AFK_LAUNCH_ENTRY:-}" ]; then
    jg_afk_launch_terminal_alive "$backend" "$target"
    return
  fi
  while [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    daemon_lock_held_by_live_daemon && return 0
    jg_afk_launch_terminal_alive "$backend" "$target" || return 1
    sleep 0.05
  done
  return 1
}

jg_afk_launch_commit_terminal() {  # <backend> <target> <extra> [already-recorded]
  local backend=$1 target=$2 extra=$3 already_recorded=${4:-0}
  if [ "$already_recorded" -ne 1 ] && ! jg_afk_launch_record_write "$backend" "$target" "$extra"; then
    jg_afk_launch_log "failed to persist daemon terminal record; closing $backend:$target"
    jg_afk_launch_close_terminal "$backend" "$target"
    return 1
  fi
  if ! jg_afk_launch_wait_ready "$backend" "$target"; then
    jg_afk_launch_log "daemon did not become ready; closing $backend:$target"
    JG_AFK_REC_BACKEND=$backend
    JG_AFK_REC_TARGET=$target
    jg_afk_launch_close_recorded
    return 1
  fi
}

jg_afk_launch_herdr_recover_created() {  # <session> <label>
  local session=$1 label=$2 workspaces ws_count wsid panes pane_count pane attempt=0
  while [ "$attempt" -lt 20 ]; do
    attempt=$((attempt + 1))
    workspaces=$(jg_backend_herdr_cli "$session" workspace list 2>/dev/null) || { sleep 0.05; continue; }
    ws_count=$(printf '%s' "$workspaces" | jq --arg want "$label" \
      '[.result.workspaces[]? | select(.label == $want)] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$ws_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$ws_count" = 1 ] || return 1
    wsid=$(printf '%s' "$workspaces" | jq -r --arg want "$label" \
      '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null) || return 1
    [ -n "$wsid" ] || return 1
    panes=$(jg_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || { sleep 0.05; continue; }
    pane_count=$(printf '%s' "$panes" | jq '[.result.panes[]?] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$pane_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$pane_count" = 1 ] || return 1
    pane=$(printf '%s' "$panes" | jq -r '.result.panes[0].pane_id // empty' 2>/dev/null) || return 1
    [ -n "$pane" ] || return 1
    printf '%s\t%s' "$wsid" "$pane"
    return 0
  done
  return 1
}

# Reconcile a recorded-but-dead terminal: if a record exists and no live daemon
# owns it, close the leaked terminal by exact id and drop the record.
jg_afk_launch_reconcile() {
  local read_result
  if daemon_lock_held_by_live_daemon; then
    return 0
  fi
  jg_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 0 ]; then
    jg_afk_launch_log "reconciling leaked daemon terminal ${JG_AFK_REC_BACKEND}:${JG_AFK_REC_TARGET}"
    jg_afk_launch_close_recorded
  elif [ "$read_result" -eq 2 ]; then
    return 1
  fi
}

jg_afk_launch_restore_backup() {  # <backup> <had-afk>
  local backup=$1 had_afk=$2 artifact result=0
  rm -f "$JG_AFK_LAUNCH_STATE/.afk" \
    "$JG_AFK_LAUNCH_STATE/.subsuper-escalations" \
    "$JG_AFK_LAUNCH_STATE/.subsuper-escalations.since" \
    "$JG_AFK_LAUNCH_STATE/.subsuper-inject-wedged" \
    "$JG_AFK_LAUNCH_STATE/.subsuper-unknown-acked" || result=1
  if [ "$had_afk" -eq 1 ]; then
    cp "$backup/.afk" "$JG_AFK_LAUNCH_STATE/.afk" || result=1
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged .subsuper-unknown-acked; do
    if [ -e "$backup/$artifact" ]; then
      cp -p "$backup/$artifact" "$JG_AFK_LAUNCH_STATE/$artifact" || result=1
    fi
  done
  if [ "$result" -eq 0 ]; then
    rm -rf "$backup" || return 1
  else
    jg_afk_launch_log "rollback restoration incomplete; backup retained at $backup"
  fi
  return "$result"
}

# Launch the daemon in a non-visible herdr terminal in the CAPTAIN's session
# (so the daemon can inject into the captain pane, which lives there). A
# dedicated background workspace (--no-focus) holds exactly one tab/pane; it
# never touches the captain's active tab. Prints the record line on success.
jg_afk_launch_create_herdr() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session out wsid pane cmd label recovered create_result
  session=${captain_target%%:*}
  if [ -z "$session" ] || [ "$session" = "$captain_target" ]; then
    jg_afk_launch_log "cannot derive herdr session from captain target '$captain_target'"
    return 1
  fi
  jg_backend_source herdr || return 1
  jg_backend_herdr_server_ensure "$session" || { jg_afk_launch_log "herdr server not ready for session '$session'"; return 1; }
  label=${JG_AFK_LAUNCH_LABEL:-"$JG_AFK_LAUNCH_WS_LABEL-$$-${RANDOM:-0}-$(date '+%s')"}
  out=$(jg_backend_herdr_cli "$session" workspace create --cwd "$JG_HOME" --label "$label" --no-focus 2>/dev/null)
  create_result=$?
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ "$create_result" -ne 0 ] && [ -n "$wsid" ] && [ -n "$pane" ]; then
    jg_afk_launch_log "herdr create failed after returning exact ids; closing $session:$pane"
    if jg_afk_launch_record_write herdr "$session:$pane" "$wsid"; then
      JG_AFK_REC_BACKEND=herdr
      JG_AFK_REC_TARGET="$session:$pane"
      jg_afk_launch_close_recorded || true
    else
      jg_afk_launch_log "failed to persist exact id for failed herdr create"
    fi
    return 1
  fi
  if [ -z "$wsid" ] || [ -z "$pane" ]; then
    recovered=$(jg_afk_launch_herdr_recover_created "$session" "$label") || {
      jg_afk_launch_log "herdr create did not yield a recoverable exact workspace/pane id"
      return 1
    }
    IFS=$'\t' read -r wsid pane <<< "$recovered"
  fi
  cmd=$(jg_afk_launch_daemon_cmd "$captain_target" "$captain_backend")
  if ! jg_afk_launch_record_write herdr "$session:$pane" "$wsid"; then
    jg_afk_launch_log "failed to persist herdr daemon terminal record; closing $session:$pane"
    jg_afk_launch_close_terminal herdr "$session:$pane"
    return 1
  fi
  if ! jg_backend_herdr_cli "$session" pane run "$pane" "$cmd" >/dev/null 2>&1; then
    jg_afk_launch_log "failed to run daemon in herdr pane $session:$pane; closing it"
    JG_AFK_REC_BACKEND=herdr
    JG_AFK_REC_TARGET="$session:$pane"
    jg_afk_launch_close_recorded || true
    return 1
  fi
  jg_afk_launch_commit_terminal herdr "$session:$pane" "$wsid" 1 || return 1
  jg_afk_launch_log "daemon launched in non-visible herdr workspace $wsid (pane $session:$pane), supervising $captain_target"
}

# Launch the daemon in a detached tmux session (never a split-window in the
# captain's window). tmux pane ids are server-global, so the daemon reaches the
# captain pane by its %id from this separate session.
jg_afk_launch_create_tmux() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session cmd hash nonce
  hash=$(printf '%s' "$JG_HOME" | cksum | cut -d' ' -f1)
  nonce="$$-${RANDOM:-0}-$(date '+%s')"
  session="jg-afk-daemon-$hash-$nonce"
  cmd=$(jg_afk_launch_daemon_cmd "$captain_target" "$captain_backend")
  if ! jg_afk_launch_record_write tmux "$session" ""; then
    jg_afk_launch_log "failed to persist planned tmux daemon session '$session'"
    return 1
  fi
  if ! tmux new-session -d -s "$session" "$cmd" 2>/dev/null; then
    jg_afk_launch_log "failed to create detached tmux daemon session '$session'"
    if ! rm -f "$JG_AFK_LAUNCH_RECORD"; then
      jg_afk_launch_log "failed to remove planned tmux daemon record after creation failure"
    fi
    return 1
  fi
  jg_afk_launch_commit_terminal tmux "$session" "" 1 || return 1
  jg_afk_launch_log "daemon launched in detached tmux session '$session', supervising $captain_target"
}

jg_afk_launch_start() {
  local captain_target captain_backend backup artifact had_afk=0 result
  jg_afk_launch_catchup_pending && return 1
  jg_afk_launch_daemon_allowed || return 1
  jg_afk_launch_record_require || return 1
  # Capture the captain pane FIRST, before creating anything.
  captain_target=$(discover_supervisor_target) || {
    jg_afk_launch_log "could not resolve the captain supervisor pane (set JG_SUPERVISOR_TARGET)"
    return 1; }
  captain_backend=$(discover_supervisor_backend) || {
    jg_afk_launch_log "could not resolve the captain supervisor backend (set JG_SUPERVISOR_BACKEND)"
    return 1; }

  mkdir -p "$JG_AFK_LAUNCH_STATE"

  if daemon_lock_held_by_live_daemon; then
    jg_afk_launch_record_validate_if_present || return 1
    if ! jg_afk_launch_flag_write; then
      jg_afk_launch_log "failed to refresh away-mode flag"
      return 1
    fi
    jg_afk_launch_log "daemon already running; refreshed away-mode flag (no new terminal)"
    return 0
  fi

  backup=$(mktemp -d "$JG_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -f "$JG_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    cp "$JG_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged .subsuper-unknown-acked; do
    if [ -e "$JG_AFK_LAUNCH_STATE/$artifact" ]; then
      cp -p "$JG_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  if ! jg_afk_launch_reconcile; then
    result=1
  else
    if jg_afk_clear_stale_artifacts "$JG_AFK_LAUNCH_STATE"; then
      result=0
    else
      jg_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    if ! jg_afk_launch_flag_write; then
      jg_afk_launch_log "failed to write away-mode flag"
      result=1
    fi
  fi

  if [ "$result" -eq 0 ]; then
    case "$captain_backend" in
      herdr) jg_afk_launch_create_herdr "$captain_target" "$captain_backend"; result=$? ;;
      tmux)  jg_afk_launch_create_tmux "$captain_target" "$captain_backend"; result=$? ;;
      *)
        jg_afk_launch_log "no non-visible daemon-launch primitive for backend '$captain_backend' yet (supported: herdr, tmux)"
        result=1
        ;;
    esac
  fi
  if [ "$result" -ne 0 ]; then
    jg_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

jg_afk_launch_start_native() {
  local backup artifact had_afk=0 result=0
  mkdir -p "$JG_AFK_LAUNCH_STATE" || return 1
  jg_afk_launch_catchup_pending && return 1
  jg_afk_launch_daemon_allowed || return 1
  jg_afk_launch_record_require || return 1
  if daemon_lock_held_by_live_daemon; then
    jg_afk_launch_record_validate_if_present || return 1
    jg_afk_launch_flag_write || return 1
    jg_afk_launch_log "daemon already running; refreshed away-mode flag"
    return 0
  fi
  backup=$(mktemp -d "$JG_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -f "$JG_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    cp "$JG_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged .subsuper-unknown-acked; do
    if [ -e "$JG_AFK_LAUNCH_STATE/$artifact" ]; then
      cp -p "$JG_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  jg_afk_launch_reconcile || result=1
  if [ "$result" -eq 0 ]; then
    if ! jg_afk_clear_stale_artifacts "$JG_AFK_LAUNCH_STATE"; then
      jg_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    elif ! jg_afk_launch_flag_write; then
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    jg_afk_launch_record_write none - native || result=1
  fi
  if [ "$result" -ne 0 ]; then
    jg_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

jg_afk_launch_stop() {
  local pid pid_identity current_identity result=0 read_result archived closed_daemon_terminal=0
  jg_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 2 ]; then
    jg_afk_launch_log "malformed daemon terminal record; refusing to stop away mode"
    return 1
  fi
  # (1) SIGTERM the daemon so its cleanup trap flushes buffered escalations
  # WHILE state/.afk is still present (the exit-ordering fix: clearing .afk
  # first would make that flush a no-op via inject_msg's presence gate).
  pid=""
  pid_identity=""
  if daemon_lock_held_by_live_daemon; then
    pid=$(daemon_lock_pid 2>/dev/null) || return 1
    pid_identity=$(jg_pid_identity "$pid" 2>/dev/null) || return 1
  fi
  if [ -n "$pid" ]; then
    if ! kill -TERM "$pid" 2>/dev/null; then
      jg_afk_launch_log "failed to signal away-mode daemon pid=$pid"
      result=1
    fi
    for _ in $(seq 1 40); do
      jg_pid_alive "$pid" || break
      sleep 0.25
    done
  fi
  if [ -n "$pid" ] && jg_pid_alive "$pid"; then
    current_identity=$(jg_pid_identity "$pid" 2>/dev/null) || {
      jg_afk_launch_log "could not confirm away-mode daemon exit; preserving lifecycle state"
      return 1
    }
    if [ "$current_identity" = "$pid_identity" ]; then
      jg_afk_launch_log "away-mode daemon did not exit after SIGTERM; preserving lifecycle state"
      return 1
    fi
  fi
  # (2) Close the daemon's own terminal by exact id. A native/none record or
  # an absent record means no terminal existed for this entry (Pi never
  # launches one).
  if [ "$read_result" -eq 0 ]; then
    if [ "$JG_AFK_REC_BACKEND" != none ]; then
      closed_daemon_terminal=1
    fi
    jg_afk_launch_close_recorded || result=1
    [ "$result" -eq 0 ] || closed_daemon_terminal=0
  fi
  # (3) Clear the away-mode flag, then (4) archive the posture record LAST so the
  # posture ends only once every daemon-side artifact is down.
  if ! rm -f "$JG_AFK_LAUNCH_STATE/.afk"; then
    jg_afk_launch_log "failed to clear away-mode flag"
    result=1
  fi
  if [ "$result" -eq 0 ] && jg_afk_contract_present "$JG_AFK_LAUNCH_STATE"; then
    if archived=$("$JG_AFK_CONTRACT_CMD" archive); then
      jg_afk_launch_log "away-posture record archived at $archived"
    else
      jg_afk_launch_log "failed to archive the away-posture record; it still stands"
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    if [ "$closed_daemon_terminal" -eq 1 ]; then
      jg_afk_launch_log "away mode stopped; daemon terminal torn down, .afk cleared, and the posture record archived"
    else
      jg_afk_launch_log "away mode stopped; no daemon terminal was running, .afk cleared, and the posture record archived"
    fi
  else
    jg_afk_launch_log "away mode stopped; terminal teardown or the record archive remains recorded for retry"
  fi
  return "$result"
}

# Roll back a failed quiet start (the header's QUIET MODE): with a quiet record
# and no live daemon, archive the record as `stop` does. Returns <status>.
jg_afk_launch_quiet_rollback() {  # <status>
  local status=$1
  if [ "$(jg_afk_launch_requested_mode)" = quiet ] && jg_afk_launch_record_quiet \
    && ! daemon_lock_held_by_live_daemon; then
    jg_afk_launch_log "the quiet daemon did not start; ending quiet mode so its record does not outlive it"
    jg_afk_launch_stop
  fi
  return "$status"
}

jg_afk_launch_main() {
  local result
  # Traps first, lock second. Acquiring before the handlers exist leaves a
  # window where a signal terminates this process by default action and leaks
  # the lock directory, which then blocks the next away-mode launch until the
  # stale-owner reclaim path clears it. jg_afk_launch_lock_release only removes
  # a lock this process owns, so arming it before acquisition is safe.
  trap jg_afk_launch_lock_release EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  jg_afk_launch_lock_acquire || return 1
  case "${1:-start}" in
    enter) shift; jg_afk_launch_enter "$@" ;;
    propose|confirm)
      jg_afk_launch_log "'$1' was retired with the wait-for-go gate: /watchover is itself the go, so run 'enter' to write the record in the same turn"
      (exit 2) ;;
    start) jg_afk_launch_start || jg_afk_launch_quiet_rollback $? ;;
    start-native) jg_afk_launch_start_native || jg_afk_launch_quiet_rollback $? ;;
    stop) jg_afk_launch_stop ;;
    reconcile) jg_afk_launch_reconcile ;;
    quiet-check) jg_afk_launch_quiet_check ;;
    -h|--help|help) jg_afk_launch_usage ;;
    *) jg_afk_launch_usage >&2; return 2 ;;
  esac
  result=$?
  jg_afk_launch_lock_release || result=1
  trap - EXIT INT TERM
  return "$result"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  jg_afk_launch_main "$@"
fi
