#!/usr/bin/env bash
# jg-control-primary-lib.sh - the `primary` target of bin/jg-control.sh:
#
#   jg-control.sh primary relaunch --clear-composer
#
# Restart this home's own primary session (Main) in the pane it already runs
# in, for the one case a repair cannot reach: a wake waits behind input-box text
# that two repairs failed to clear. Only the watcher's and the sentinel's repair
# path calls it, and only after those two repairs failed; this file cannot
# count them, so the caller owns that condition (docs/agent-control.md).
#
# The target is not a task id. A task record names its own endpoint; the
# primary has none, so it is PROVEN instead, from the three records that
# already name it:
#   - state/.lock is held by a live process that is a verified harness;
#   - state/.lock-session names the session id the lock owner trusts;
#   - exactly one Herdr pane in this home's Herdr session reports that same
#     agent session id (the match core/sentinel/bin/jg-sentinel.sh already uses
#     to find the pane it wakes).
# Anything else - no lock, a dead holder, no pane, two panes, a pane of another
# agent, a caller running inside the session itself - refuses before any key
# or signal is sent.
#
# Refused whatever the proof says:
#   - `--force`, or any option but --clear-composer: no bypass exists;
#   - a second attempt inside JG_CONTROL_PRIMARY_GAP seconds (600) of the last
#     one that touched the session, recorded as one refused row for the lead;
#   - a session whose turn is running (the wake arrives at the end of a turn);
#   - an input box that holds anything but our own doorbell line or a leading
#     part of it (jg_composer_own_doorbell_length): a person's text is never
#     cleared, and the relaunch waits for them.
#
# Steps, each verified before the next:
#   1 prove     the lock, session id, pane and harness above;
#   2 read      the live harness process's argv and working directory, which are
#               the recorded harness and model, from /proc (refused where
#               /proc is absent, because argv cannot be recovered intact);
#   3 end       SIGTERM to that one proven process, never SIGKILL; the pane's
#               agent must read dead within JG_CONTROL_EXIT_WAIT;
#   4 start     the same argv typed into the same pane's shell, in the same
#               working directory;
#   5 confirm   the pane's agent reads alive within JG_CONTROL_LAUNCH_WAIT.
# The new session's own session start then takes the lock and drains the wake
# queue; this reports whether the lock changed hands and never forces it.
# Nothing is discarded: the old session's transcript, the home's records and
# every uncommitted change stay as they were. Each attempt adds one row to
# data/primary-relaunches.tsv: epoch, result, pane, harness, model, reason.
#
# Sourced by bin/jg-control.sh, which owns die, POLL, EXIT_WAIT, LAUNCH_WAIT,
# STATE, DATA, SCRIPT_DIR and the libraries used below.

JG_CONTROL_PRIMARY_GAP_DEFAULT=600
# shellcheck source=bin/jg-session-lock-lib.sh
. "${BASH_SOURCE[0]%/*}/jg-session-lock-lib.sh"
# shellcheck source=bin/jg-operational-input.sh
. "${BASH_SOURCE[0]%/*}/jg-operational-input.sh"

# Print the pid in line 1 of state/.lock when it is a live process.
jg_control_primary_lock_pid() {
  local pid
  # shellcheck disable=SC2153 # STATE is set by bin/jg-control.sh, which sources this file
  pid=$(head -n 1 "$STATE/.lock" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

# 0 when <pid> is this process or one of its ancestors.
jg_control_primary_is_ancestor() {  # <pid>
  local want=$1 cur=$$ next
  while [ -n "$cur" ] && [ "$cur" -gt 1 ] 2>/dev/null; do
    [ "$cur" != "$want" ] || return 0
    next=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')
    [ "$next" != "$cur" ] || break
    cur=$next
  done
  return 1
}

# jg_control_primary_prove: set PRIMARY_PID, PRIMARY_SID, PRIMARY_TARGET,
# PRIMARY_AGENT, PRIMARY_HARNESS. Prints the refusal on stderr and returns 1.
jg_control_primary_prove() {
  local session panes comm args
  PRIMARY_PID=$(jg_control_primary_lock_pid) \
    || { echo "no live process holds $STATE/.lock; this home has no running primary session to relaunch" >&2; return 1; }
  PRIMARY_SID=$(head -n 1 "$STATE/.lock-session" 2>/dev/null)
  [ -n "$PRIMARY_SID" ] \
    || { echo "$STATE/.lock-session names no session id, so no pane can be proven to be the locked primary" >&2; return 1; }
  comm=$(ps -o comm= -p "$PRIMARY_PID" 2>/dev/null)
  args=$(ps -o args= -p "$PRIMARY_PID" 2>/dev/null)
  jg_harness_process_matches "$comm" "$args" \
    || { echo "the process holding the lock (pid $PRIMARY_PID, '$comm') is not a verified harness" >&2; return 1; }
  jg_control_primary_is_ancestor "$PRIMARY_PID" \
    && { echo "this command runs inside the primary session (pid $PRIMARY_PID); a session cannot end and restart itself" >&2; return 1; }
  jg_backend_source herdr || { echo "the Herdr adapter did not load" >&2; return 1; }
  session=${JG_CONTROL_PRIMARY_HERDR_SESSION:-${HERDR_SESSION:-default}}
  panes=$(jg_backend_herdr_cli "$session" api snapshot 2>/dev/null \
    | jq -r --arg sid "$PRIMARY_SID" '.result.snapshot.agents[]? | select(.agent_session.value == $sid) | "\(.pane_id)\t\(.agent)"' 2>/dev/null) \
    || panes=
  if [ -z "$panes" ] || [ "$(printf '%s\n' "$panes" | wc -l)" -ne 1 ]; then
    echo "not exactly one Herdr pane in session '$session' runs the locked session $PRIMARY_SID; this is not the locked primary" >&2
    return 1
  fi
  PRIMARY_TARGET=$session:${panes%%$'\t'*}
  PRIMARY_AGENT=${panes#*$'\t'}
  if ! PRIMARY_HARNESS=$(jg_control_harness_family "$PRIMARY_AGENT") \
    || ! jg_control_harness_supported "$PRIMARY_HARNESS"; then
    echo "pane $PRIMARY_TARGET runs agent '$PRIMARY_AGENT', which has no verified control mechanics" >&2
    return 1
  fi
}

# The newest epoch of an attempt that touched the session; 0 when none.
jg_control_primary_last_attempt() {
  awk -F'\t' '$2 == "relaunched" || $2 == "failed" { t = $1 } END { print t + 0 }' \
    "$DATA/primary-relaunches.tsv" 2>/dev/null || echo 0
}

jg_control_primary_record() {  # <result> <reason>
  mkdir -p "$DATA" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "${PRIMARY_TARGET:--}" \
    "${PRIMARY_HARNESS:--}" "${PRIMARY_MODEL:--}" "$2" >>"$DATA/primary-relaunches.tsv" 2>/dev/null \
    || echo "warning: could not write $DATA/primary-relaunches.tsv" >&2
}

jg_control_primary_refuse() {  # <reason>
  jg_control_primary_record refused "$1"
  die "primary relaunch refused: $1"
}

# 0 when the input box holds our own doorbell line (or a leading part of it).
jg_control_primary_box_is_ours() {  # <target>
  local held record line
  held=$(jg_backend_capture herdr "$1" "$JG_COMPOSER_CAPTURE_LINES" 2>/dev/null) \
    && held=$(jg_composer_extract_selected_content styled=0 "$held") || return 1
  for record in "$STATE/$JG_OPERATIONAL_RECORD_DIRNAME"/*.msg; do
    [ -f "$record" ] || continue
    line="$JG_OPERATIONAL_DOORBELL_PREFIX$(cd -P "$(dirname "$record")" && pwd -P)/${record##*/}$JG_OPERATIONAL_DOORBELL_SUFFIX"
    jg_composer_own_doorbell_length "$held" "$line" >/dev/null && return 0
  done
  return 1
}

# Print the argv of <pid> as one shell-quoted line, or return 1.
jg_control_primary_launch_line() {  # <pid>
  local arg out='' n=0
  [ -r "/proc/$1/cmdline" ] || return 1
  while IFS= read -r -d '' arg; do
    case "$arg" in *$'\n'*|*$'\r'*) return 1 ;; esac
    out+=" $(printf '%q' "$arg")"
    n=$((n + 1))
  done <"/proc/$1/cmdline"
  [ "$n" -gt 0 ] || return 1
  printf '%s' "${out# }"
}

jg_control_primary_model_of() {  # <pid>
  local arg prev='' model=-
  while IFS= read -r -d '' arg; do
    case "$prev" in --model|-m) model=$arg ;; esac
    case "$arg" in --model=*) model=${arg#--model=} ;; esac
    prev=$arg
  done <"/proc/$1/cmdline" 2>/dev/null
  printf '%s' "$model"
}

jg_control_primary_main() {
  local lock=$STATE/.control-primary.lock now last gap state cwd line sent i=0 waited=0
  [ "$VERB" = relaunch ] || die "the primary target takes 'relaunch --clear-composer' only"
  [ "$FORCE_SEEN" = 0 ] || die "primary relaunch has no --force: a refusal is fixed at its cause"
  [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] && [ "$NOTE_SET" = 0 ] \
    || die "primary relaunch restarts the recorded harness and model; --harness, --model, --effort and --note do not apply"
  [ "$CLEAR_COMPOSER" = 1 ] || die "primary relaunch requires --clear-composer: the restart discards only our own unsent doorbell line, so it must be asked for"
  jg_lock_try_acquire "$lock" || die "another primary relaunch is already running"
  # shellcheck disable=SC2064 # the lock path is fixed now
  trap "jg_lock_release '$lock'" EXIT

  PRIMARY_TARGET=""; PRIMARY_HARNESS=""; PRIMARY_MODEL=""
  jg_control_primary_prove 2>"$STATE/.control-primary.why" \
    || jg_control_primary_refuse "$(tr '\n' ' ' <"$STATE/.control-primary.why")"
  rm -f "$STATE/.control-primary.why"
  PRIMARY_MODEL=$(jg_control_primary_model_of "$PRIMARY_PID")

  now=$(date +%s)
  last=$(jg_control_primary_last_attempt)
  gap=${JG_CONTROL_PRIMARY_GAP:-$JG_CONTROL_PRIMARY_GAP_DEFAULT}
  [ $((now - last)) -ge "$gap" ] \
    || jg_control_primary_refuse "the last relaunch was $((now - last))s ago; at most one in ${gap}s"

  [ "$(jg_backend_busy_state herdr "$PRIMARY_TARGET")" != busy ] \
    || jg_control_primary_refuse "the session is mid-turn; the waiting wake arrives when the turn ends"
  case "$(jg_backend_composer_state herdr "$PRIMARY_TARGET" 2>/dev/null)" in
    empty) ;;
    pending)
      jg_control_primary_box_is_ours "$PRIMARY_TARGET" \
        || jg_control_primary_refuse "the input box holds text that is not our doorbell line; a person may be typing, and it is never cleared"
      ;;
    *) jg_control_primary_refuse "the input box state is not proven empty or our own line" ;;
  esac

  cwd=$(readlink "/proc/$PRIMARY_PID/cwd" 2>/dev/null) && [ -d "$cwd" ] \
    || jg_control_primary_refuse "the session's working directory cannot be read"
  line=$(jg_control_primary_launch_line "$PRIMARY_PID") \
    || jg_control_primary_refuse "the session's launch command cannot be read intact from /proc/$PRIMARY_PID/cmdline"

  # End: one SIGTERM to the proven process, then wait for the pane to read dead.
  kill -TERM "$PRIMARY_PID" 2>/dev/null \
    || { jg_control_primary_record failed "SIGTERM to pid $PRIMARY_PID was refused"; die "could not signal the primary session (pid $PRIMARY_PID)"; }
  while :; do
    state=$(jg_backend_agent_state herdr "$PRIMARY_TARGET")
    [ "$state" != dead ] || break
    awk -v e="$waited" -v t="$EXIT_WAIT" 'BEGIN{exit !(e < t)}' \
      || { jg_control_primary_record failed "the session did not stop within ${EXIT_WAIT}s (pane reads $state)"; die "the primary session did not stop within ${EXIT_WAIT}s (pane reads '$state'); nothing was started"; }
    sleep "$POLL"
    waited=$(awk -v e="$waited" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done

  # Start: the same command, in the same directory, in the same pane's shell.
  sent=$(jg_backend_send_text_submit herdr "$PRIMARY_TARGET" "cd $(printf '%q' "$cwd") && $line" 3 "$POLL" 1.2) \
    && [ "$sent" != send-failed ] \
    || { jg_control_primary_record failed "the session stopped but its launch command could not be typed"; die "the primary session stopped, but its launch command could not be typed into $PRIMARY_TARGET; start it by hand in $cwd: $line"; }
  waited=0
  while :; do
    [ "$(jg_backend_agent_state herdr "$PRIMARY_TARGET")" != alive ] || break
    awk -v e="$waited" -v t="$LAUNCH_WAIT" 'BEGIN{exit !(e < t)}' \
      || { jg_control_primary_record failed "the new session did not come up within ${LAUNCH_WAIT}s"; die "the replacement primary session did not come up within ${LAUNCH_WAIT}s in $PRIMARY_TARGET; start it by hand in $cwd: $line"; }
    sleep "$POLL"
    waited=$(awk -v e="$waited" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done

  # The lock changes hands when the new session runs its own session start.
  last=pending
  while [ "$i" -lt 20 ]; do
    now=$(jg_control_primary_lock_pid) && [ "$now" != "$PRIMARY_PID" ] && { last=taken; break; }
    sleep "$POLL"
    i=$((i + 1))
  done
  jg_control_primary_record relaunched "lock=$last"
  echo "relaunched primary harness=$PRIMARY_HARNESS model=$PRIMARY_MODEL backend=herdr endpoint=$PRIMARY_TARGET lock=$last"
}
