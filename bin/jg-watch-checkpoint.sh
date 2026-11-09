#!/usr/bin/env bash
# Run one bounded foreground watcher checkpoint for harnesses that should not
# rely on background-task completion to wake the model.
#
# SUPERVISION HOST. A home opted in with config/supervision-host
# (docs/configuration.md "Supervision host" owns the gate;
# config/supervision-host-off opts out, and a Codex home without the file does not run the host) runs
# bin/jg-supervision-host.sh in the watcher's place for the checkpoint's bound,
# as the host's park boundary; the host takes away-posture wakes itself and
# returns only when main is needed (its header owns the output read here).
# While an away record state/.afk-contract exists (never quiet mode's, whose
# captain is present: bin/jg-afk-contract.sh mode), the bound is
# raised to JG_CODEX_WATCH_CHECKPOINT_AWAY (default 3600) when that is longer,
# so a parked main is not woken every few minutes; an engine turn that starts
# before the bound may finish after it. A close that carries a wake or a
# "supervision-host:" line other than the park boundary passes through as a
# wake; the boundary alone is the ordinary quiet checkpoint. On a home that
# does not run the host nothing below changes.
#
# CADENCE MARKER AND OWN BOUND. Every run writes state/.checkpoint-cadence
# (cadence=<seconds>, phase=<running|wake|quiet|hard-bound>) at its start and
# again as it ends, whatever the harness; bin/jg-supervision-lib.sh reads it so a
# lead between two checkpoints is healthy for the cadence plus the guard grace,
# and alarms once past it. A checkpoint also bounds itself: the child it runs
# gets its signal at the bound, and KILL after a grace (JG_CHECKPOINT_KILL_GRACE,
# default 10 seconds for the host; the watcher keeps its own cleanup bound), so a
# child that ignores the signal cannot hold the checkpoint open. The host's outer
# bound adds JG_CHECKPOINT_HOST_GRACE (default 120). A bound that fired is
# recorded as phase=hard-bound and reported on stderr with exit 1.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
SECONDS_ARG=${JG_CODEX_WATCH_CHECKPOINT:-180}

usage() {
  cat <<'EOF'
Usage: jg-watch-checkpoint.sh [--seconds <n>]

Run bin/jg-watch.sh in the foreground for a bounded checkpoint.
On an actionable watcher wake, pass through the watcher output and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --seconds)
      [ "$#" -gt 1 ] || { echo "error: --seconds requires a value" >&2; exit 2; }
      SECONDS_ARG=$2
      shift 2
      ;;
    --seconds=*)
      SECONDS_ARG=${1#--seconds=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SECONDS_ARG" in
  ''|*[!0-9]*) echo "error: --seconds must be a positive integer" >&2; exit 2 ;;
  0) echo "error: --seconds must be greater than zero" >&2; exit 2 ;;
esac

# A checkpoint is neither an ordinary watcher start nor an Option B handling
# successor. It keeps an announced recovery episode stable while preserving the
# watcher's ordinary recovery of a generation that becomes pending.
export JG_WATCH_FOREGROUND_CHECKPOINT=1

OUT=$(mktemp "${TMPDIR:-/tmp}/jg-watch-checkpoint.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/jg-watch-checkpoint.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}

# write_marker <cadence> <phase>: the harness-agnostic liveness record a lead's
# supervision status reads (bin/jg-supervision-lib.sh). A failed write never
# fails the checkpoint: without it the lead reads as before.
MARKER="$STATE/.checkpoint-cadence"
MARKER_CADENCE=$SECONDS_ARG
MARKER_PHASE=running
write_marker() {  # <cadence> <phase>
  local tmp="$MARKER.$$"
  [ ! -L "$MARKER" ] || return 0
  { printf 'cadence=%s\nphase=%s\n' "$1" "$2" > "$tmp" && mv -f "$tmp" "$MARKER"; } 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}
finish() {
  rm -f "$OUT" "$ERR"
  write_marker "$MARKER_CADENCE" "$MARKER_PHASE"
}
trap finish EXIT
mkdir -p "$STATE" 2>/dev/null || true
write_marker "$MARKER_CADENCE" running

run_with_perl_timeout() {  # <seconds> <signal> <kill-after-seconds> <command...>
  perl -e '
    use POSIX qw(:sys_wait_h);
    my $seconds = shift;
    my $signal = shift;
    my $kill_after = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    my $timed_out = 0;
    local $SIG{ALRM} = sub {
      if ($timed_out) {
        kill "KILL", -$pid;
        waitpid $pid, 0;
        exit 124;
      }
      $timed_out = 1;
      kill $signal, -$pid;
      alarm($kill_after) if $kill_after;
    };
    alarm $seconds;
    while (1) {
      my $waited = waitpid $pid, WNOHANG;
      if ($waited == $pid) {
        alarm 0;
        exit($timed_out ? 124 : ($? >> 8));
      }
      select undef, undef, undef, 0.05;
    }
  ' "$@"
}

run_bounded() {  # <seconds> <signal> <kill-after-seconds> <command...>
  local seconds=$1 signal=$2 kill_after=$3
  shift 3
  if command -v timeout >/dev/null 2>&1; then
    if [ "$kill_after" -gt 0 ]; then
      timeout --signal="$signal" --kill-after="${kill_after}s" "$seconds" "$@"
    else
      timeout --signal="$signal" "$seconds" "$@"
    fi
  elif command -v gtimeout >/dev/null 2>&1; then
    if [ "$kill_after" -gt 0 ]; then
      gtimeout --signal="$signal" --kill-after="${kill_after}s" "$seconds" "$@"
    else
      gtimeout --signal="$signal" "$seconds" "$@"
    fi
  else
    run_with_perl_timeout "$seconds" "$signal" "$kill_after" "$@"
  fi
}

positive_or() {  # <value> <default>
  case "$1" in ''|0*|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

# bound_hit <status>: 0 when a bounded child ended by the bound (124) or by the KILL after it (137).
bound_hit() { [ "$1" -eq 124 ] || [ "$1" -eq 137 ]; }

# shellcheck source=bin/jg-supervision-engine-lib.sh
. "$SCRIPT_DIR/jg-supervision-engine-lib.sh"
if jg_supervision_host_enabled "$CONFIG" codex; then
  BOUND=$SECONDS_ARG
  if [ -f "$STATE/.afk-contract" ] \
    && [ "$(JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-afk-contract.sh" mode 2>/dev/null)" != quiet ]; then
    AWAY_BOUND=$(positive_or "${JG_CODEX_WATCH_CHECKPOINT_AWAY:-}" 3600)
    [ "$AWAY_BOUND" -le "$BOUND" ] 2>/dev/null || BOUND=$AWAY_BOUND
  fi
  # The host's park boundary stays below the 28800-second registration.
  [ "$BOUND" -lt 27000 ] 2>/dev/null || BOUND=27000
  LIMIT=$(( BOUND + $(positive_or "${JG_SUPERVISION_HOST_TURN_TIMEOUT:-}" 1200) + $(positive_or "${JG_SUPERVISION_ENGINE_GRACE:-}" 30) ))
  MARKER_CADENCE=$BOUND
  write_marker "$MARKER_CADENCE" running
  set +e
  # The host ends its own park; the outer bound only catches a host that
  # outlived every one of its own bounds, and KILL follows TERM so a host that
  # ignores TERM cannot hold the checkpoint open.
  JG_SUPERVISION_HOST_PRIMARY=codex JG_SUPERVISION_HOST_PARK_SECONDS=$BOUND JG_SUPERVISION_HOST_PARK_LIMIT=$LIMIT \
    run_bounded $((LIMIT + $(positive_or "${JG_CHECKPOINT_HOST_GRACE:-}" 120))) TERM \
    "$(positive_or "${JG_CHECKPOINT_KILL_GRACE:-}" 10)" "$SCRIPT_DIR/jg-supervision-host.sh" park >"$OUT" 2>"$ERR"
  RC=$?
  set -e
  if grep -E '^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)' "$OUT" 2>/dev/null \
    | grep -Ev '^supervision-host: cycle boundary' >/dev/null; then
    MARKER_PHASE=wake
    grep -Ev '^watcher: (started|attached) ' "$OUT"
    [ ! -s "$ERR" ] || cat "$ERR" >&2
    exit 0
  fi
  if grep -E '^supervision-host: cycle boundary' "$OUT" >/dev/null 2>&1; then
    MARKER_PHASE=quiet
    printf 'checkpoint: no actionable wake within %ss\n' "$BOUND"
    exit 124
  fi
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  if bound_hit "$RC"; then
    MARKER_PHASE=hard-bound
    echo "checkpoint: the supervision host outlived its own bound of ${BOUND}s and was stopped" >&2
    exit 1
  fi
  [ "$RC" -ne 0 ] || RC=1
  exit "$RC"
fi

# The watcher's cleanup gets JG_WATCHER_CLEANUP_LOCK_BOUND (default 2) seconds after the INT, then KILL.
CLEANUP_BOUND=$(positive_or "${JG_WATCHER_CLEANUP_LOCK_BOUND:-}" 2)
[ "$CLEANUP_BOUND" -le 5 ] || CLEANUP_BOUND=5
set +e
# Interrupt the checkpoint's active check group so the watcher's native EXIT cleanup can release its lock; ordinary watcher shutdown still uses TERM.
run_bounded "$SECONDS_ARG" INT "$CLEANUP_BOUND" "$SCRIPT_DIR/jg-watch.sh" >"$OUT" 2>"$ERR"
RC=$?
set -e

if grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" >/dev/null 2>&1; then
  MARKER_PHASE=wake
  cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  exit 0
fi

if grep -E '^watcher: already running' "$OUT" "$ERR" >/dev/null 2>&1; then
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  echo "checkpoint: watcher is already running outside this foreground checkpoint" >&2
  exit 1
fi

if [ "$RC" -eq 137 ]; then
  MARKER_PHASE=hard-bound
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  echo "checkpoint: the watcher did not stop at its bound of ${SECONDS_ARG}s and was killed" >&2
  exit 1
fi

if [ "$RC" -eq 124 ]; then
  MARKER_PHASE=quiet
  printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
  exit 124
fi

[ ! -s "$OUT" ] || cat "$OUT"
[ ! -s "$ERR" ] || cat "$ERR" >&2
exit "$RC"
