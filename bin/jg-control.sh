#!/usr/bin/env bash
# jg-control.sh - the CONTROL PLANE for a juggernaut-owned agent: allowlisted
# lifecycle verbs addressed to an exact task id.
#
# Usage: jg-control.sh <task-id> interrupt
#        jg-control.sh <task-id> exit
#        jg-control.sh <task-id> relaunch [--harness <name>] [--model <name>]
#                                         [--effort <level>]
#                                         (--note <text> | --note-file <path>)
#
# Why this exists, and how it differs from jg-send.sh. bin/jg-send.sh is the
# DATA plane: conversational text for the agent to read, always routing-marked
# for a kind=squad_lead target so the reply returns through the status path.
# That marking is right for a message and wrong for a lifecycle command - a
# marked "/quit" arrives as ordinary chat the agent reasons ABOUT instead of
# executing. This script is the control plane: semantic process control with a
# closed verb list, per-harness mechanics owned by an executable adapter
# (bin/jg-control-lib.sh) rather than improvised in agent prose, and a verified
# postcondition for every action. There is deliberately NO arbitrary-text and
# NO generic raw-key entry point here; jg-send remains the only way to send an
# agent something to read.
#
#   interrupt  Deliver the harness's verified interrupt sequence. The agent
#              keeps running. Postcondition: delivery succeeded, the endpoint
#              still exists, and the agent is still alive where the backend can
#              classify that. Cancellation is confirmed only from an adapter-
#              owned acknowledgement and otherwise reported unconfirmed. Busy
#              state is never rewritten as proof of the action. Devin
#              cancellation invalidates it to unknown because its native hooks
#              emit no cancellation close; this is not a success claim.
#              An adapter whose repeated interrupt key does something else on
#              an idle agent (Devin's revert picker) sends its later presses
#              only after the first press rendered a running turn, and
#              otherwise reports `cancel=not-running` having sent one press.
#   exit       Stop the agent, preserving its terminal endpoint, worktree, and
#              every uncommitted change. Interrupts first when the task reads
#              busy, then submits the harness's exit command. An exact Claude
#              background-work dialog with Exit and stop tasks selected is
#              confirmed; detach and unknown dialogs are refused. A Claude
#              startup gate (folder trust or external imports) is never
#              answered, because Claude stores any answer as the project's
#              decision; its endpoint is closed instead and the outcome is
#              `endpoint-gone`. Postcondition:
#              the backend's recovery-grade classifier reports the agent gone.
#              A verified exit also records state/<id>.exit; the watcher skips a
#              lane whose exit is newer than its spawn, so a dead endpoint cannot
#              emit stale on every arm. The task record keeps window= for relaunch.
#              Already-stopped is success (idempotent). An endpoint that reads
#              `missing` is put through the control plane's per-backend absence
#              proof (jg_control_endpoint_absence_verdict) before anything is
#              claimed about it, because `missing` also covers an endpoint that
#              is merely unreachable from this seat. That proof exists only on
#              HERDR, whose reads are scoped to the session the record names:
#              proven gone reports `endpoint-gone` rather than
#              `already-stopped`, because the endpoint this verb normally
#              preserves did not survive; a pane that turns out to be there and
#              idle is the ordinary `already-stopped`; one whose agent is back
#              takes the ordinary interrupt-then-exit path. A tmux `missing`
#              always REFUSES: a task record carries no socket identity for its
#              endpoint, so this verb cannot tell a destroyed window from one on
#              a tmux server it cannot address, and it will not claim a stop it
#              cannot see.
#   relaunch   Transactionally replace the running agent with a new one, in the
#              SAME worktree - and the same endpoint whenever that endpoint
#              still exists - on the same or a newly chosen
#              harness/model/effort - so switching harness is one ordinary use
#              of this verb. When the recorded endpoint is instead proven gone -
#              a Herdr pane or workspace destroyed in churn - the launch owner
#              re-creates one in that worktree, in the herdr session the record
#              names, and the task's record rebinds to it; that is how a task
#              whose terminal was destroyed is reclaimed by the home that owns
#              it, rather than being stranded with a parked approval nobody can
#              answer. Reclaim is HERDR-ONLY for the reason `exit` gives above:
#              a tmux `missing` cannot be proven absent from a task record, so
#              it refuses.
#              An explicit `default` model or effort clears that
#              axis for the replacement. A same-harness relaunch whose record
#              has no stored model refuses unless a model is named or resolved
#              from configuration. With no explicit axis, a squad_lead
#              re-resolves its durable profile through jg-harness.sh with its
#              id (per-mate pin or global fallback), exactly as any other
#              respawn does, while a ship or scout keeps the exact adapter
#              already recorded for it.
#              A prefixed raw-command basename cannot reconstruct its launch
#              command, so relaunch requires an explicit --harness for it.
#              A replacement Claude or Pi profile must also pass this home's
#              worker account pin (bin/jg-worker-account-lib.sh) here, so a pin
#              that no longer resolves or is signed out refuses before the old
#              agent stops.
#              The same pre-stop refusal applies to this home's worker tool
#              exclusions (bin/jg-exclude-tools-lib.sh): a malformed list, or a
#              replacement runtime that cannot hide the listed tools.
#              --note is required for a ship or scout, whose replacement
#              inherits the local copy but none of the conversation; a
#              squad_lead reconciles its own home's records at startup, so its
#              standing charter is never rewritten.
#              Records a durable checkpoint and that note, exits the old agent,
#              then delegates the launch to its single owner,
#              bin/jg-spawn.sh --relaunch. A failure before publication keeps
#              the prior durable record in place and reports the concrete
#              state; it never leaves a half-transitioned task claiming to be
#              running.
#
# Teardown and discard are NOT verbs here and never will be. `exit` stops an
# agent and preserves everything else; removing a worktree, killing an
# endpoint, or discarding work stays with bin/jg-teardown.sh, which owns the
# landed-work test.
#
# `resume` is not a verb: it is not deterministic across the verified adapters
# (bin/jg-control-lib.sh's header owns that reasoning). `relaunch` covers the
# same need for every adapter because the brief on disk, not a harness-private
# session, is the durable instruction.
#
# Targeting is EXACT: only a bare task id with a state/<id>.meta record in
# THIS home is accepted, and the record must pass the shared endpoint-identity
# validation (bin/jg-backend.sh's jg_backend_validate_task_endpoint). A legacy
# jg-<id> label, an explicit session:window endpoint, and a bare window name
# are all refused - a lifecycle command delivered to the wrong endpoint is far
# worse than a loud refusal.
#
# A remotely placed squad_lead is refused by name: its agent runs on another
# host, so no postcondition this plane verifies could be read for it here.
#
# Fail-closed boundaries:
#   - An unverified harness, or a harness whose control mechanics are unknown,
#     is refused rather than guessed at.
#   - A backend that cannot deliver the harness's interrupt key is refused
#     (Orca's terminal API has no Escape).
#   - `exit` and `relaunch` require a backend with a recovery-grade agent-state
#     classifier (tmux, herdr), because without one the "the agent stopped"
#     postcondition cannot be proven. zellij, orca, and cmux are refused rather
#     than reported as successful blind.
#   - An ambiguous or unreadable endpoint state refuses; only a positively
#     classified state acts.
#   - A composer that visibly holds pending text refuses before an exit command
#     is typed, so existing text is preserved instead of being concatenated.
#
# Candidate execution without installation: invoke the candidate root's
# bin/jg-control.sh with JG_HOME set to the owning home and JG_ROOT_OVERRIDE
# set to that candidate root. Records and config still belong to JG_HOME;
# executable owners come from the candidate. Unset unrelated JG_STATE_OVERRIDE,
# JG_DATA_OVERRIDE and JG_CONFIG_OVERRIDE rather than redirecting task identity.
# A refusal still requires ordinary recovery; never bypass lifecycle guards.
#
# Environment knobs (all bounded waits, seconds):
#   JG_CONTROL_POLL              poll interval for postcondition waits (0.5)
#   JG_CONTROL_SETTLE_WAIT       adapter acknowledgement wait after interrupt (5)
#   JG_CONTROL_ARM_WAIT          wait for an armed interrupt's rendered proof
#                                after the press gap (1.5)
#   JG_CONTROL_EXIT_WAIT         alive->dead wait after the exit command (30)
#   JG_CONTROL_LAUNCH_WAIT       dead->alive wait after a relaunch (90)
#   JG_CONTROL_EXIT_RETRIES      Enter retries for the exit command (3)
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
    jg_compat_marker_ok() { [ "${1-}" = JUGGERNAUT_OP ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/jg-gate-refuse-lib.sh
. "$SCRIPT_DIR/jg-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# drive a operator's lifecycle (see bin/jg-gate-refuse-lib.sh).
jg_refuse_if_gate_agent

if [ -z "${JG_HOME+x}" ] || [ -z "${JG_HOME:-}" ]; then
  echo "error: JG_HOME is not set; jg-control refuses to resolve a task without an explicit juggernaut home" >&2
  exit 1
fi
[ -d "$JG_HOME" ] || {
  echo "error: JG_HOME '$JG_HOME' is not a directory" >&2
  exit 1
}
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; jg-control cannot resolve tasks for JG_HOME '$JG_HOME'" >&2
  exit 1
}

# shellcheck source=bin/jg-backend.sh
. "$SCRIPT_DIR/jg-backend.sh"
# shellcheck source=bin/jg-busy-lib.sh
. "$SCRIPT_DIR/jg-busy-lib.sh"
# shellcheck source=bin/jg-control-lib.sh
. "$SCRIPT_DIR/jg-control-lib.sh"
# shellcheck source=bin/jg-composer-lib.sh
. "$SCRIPT_DIR/jg-composer-lib.sh"
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-worker-account-lib.sh
. "$SCRIPT_DIR/jg-worker-account-lib.sh"
# Account pool (core/account-pool): the pool hook every launch and relaunch routes through, and a
# no-op in a fixture checkout copied from bin/ alone, which carries no core/ tree.
_jg_ap=$SCRIPT_DIR/../core/account-pool/bin/jg-account-pool-lib.sh
if [ -r "$_jg_ap" ]; then
  # shellcheck source=core/account-pool/bin/jg-account-pool-lib.sh
  . "$_jg_ap" || { printf 'error: %s failed to load\n' "$_jg_ap" >&2; exit 1; }
else
  jg_account_hook() { :; }
fi
# shellcheck source=bin/jg-exclude-tools-lib.sh
. "$SCRIPT_DIR/jg-exclude-tools-lib.sh"

POLL=${JG_CONTROL_POLL:-0.5}
SETTLE_WAIT=${JG_CONTROL_SETTLE_WAIT:-5}
ARM_WAIT=${JG_CONTROL_ARM_WAIT:-1.5}
EXIT_WAIT=${JG_CONTROL_EXIT_WAIT:-30}
LAUNCH_WAIT=${JG_CONTROL_LAUNCH_WAIT:-90}
EXIT_RETRIES=${JG_CONTROL_EXIT_RETRIES:-3}

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

CONTROL_LOCK=
CONTROL_LOCK_HELD=0
RELAUNCH_ACTIVE=0
RELAUNCH_PHASE=start

control_cleanup() {
  local status=$?
  if [ "$RELAUNCH_ACTIVE" = 1 ] \
     && declare -F relaunch_rollback >/dev/null 2>&1; then
    relaunch_rollback || true
  fi
  # Remove the dialog file while the lock is still held: once it is released,
  # the next lifecycle command for this task writes the same path.
  if [ -n "${JG_COMPOSER_DIALOG_SINK:-}" ]; then
    rm -f "$JG_COMPOSER_DIALOG_SINK"
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    jg_lock_release "$CONTROL_LOCK" || true
  fi
  if declare -F jg_lease_guard_release >/dev/null 2>&1; then
    jg_lease_guard_release || true
  fi
  return "$status"
}

# --- argument parsing -------------------------------------------------------

RAW_ID=${1:-}
VERB=${2:-}
[ -n "$RAW_ID" ] && [ -n "$VERB" ] || { usage >&2; exit 2; }
shift 2

if ! jg_control_verb_allowed "$VERB"; then
  {
    if [ "$VERB" = resume ]; then
      echo "error: 'resume' is not a control verb: resuming an exited agent is not deterministic across the verified adapters (codex and grok need a session id printed at exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, and kimi have no verified pane-resume contract). Use 'relaunch', which carries the brief plus a progress note into a fresh agent on any adapter."
    else
      echo "error: '$VERB' is not a control verb"
    fi
    echo "allowed verbs:"
    jg_control_verbs | sed 's/^/  /'
  } >&2
  exit 2
fi

NEW_HARNESS=
NEW_MODEL=
NEW_EFFORT=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
NOTE=
NOTE_SET=0
control_want_value=
eval "$(jg_account_hook argv "$@")"
for control_arg in "$@"; do
  if [ -n "$control_want_value" ]; then
    case "$control_arg" in
      --*) die "--$control_want_value requires a value" ;;
    esac
    case "$control_want_value" in
      harness) NEW_HARNESS=$control_arg; HARNESS_SET=1 ;;
      model) NEW_MODEL=$control_arg; MODEL_SET=1 ;;
      effort) NEW_EFFORT=$control_arg; EFFORT_SET=1 ;;
      note) NOTE=$control_arg; NOTE_SET=1 ;;
      note_file)
        [ -f "$control_arg" ] || die "--note-file '$control_arg' is not a readable file"
        NOTE=$(cat "$control_arg")
        NOTE_SET=1
        ;;
    esac
    control_want_value=
    continue
  fi
  case "$control_arg" in
    --harness) control_want_value=harness ;;
    --harness=*) NEW_HARNESS=${control_arg#--harness=}; HARNESS_SET=1 ;;
    --model) control_want_value=model ;;
    --model=*) NEW_MODEL=${control_arg#--model=}; MODEL_SET=1 ;;
    --effort) control_want_value=effort ;;
    --effort=*) NEW_EFFORT=${control_arg#--effort=}; EFFORT_SET=1 ;;
    --note) control_want_value=note ;;
    --note=*) NOTE=${control_arg#--note=}; NOTE_SET=1 ;;
    --note-file) control_want_value=note_file ;;
    --note-file=*)
      [ -f "${control_arg#--note-file=}" ] || die "--note-file '${control_arg#--note-file=}' is not a readable file"
      NOTE=$(cat "${control_arg#--note-file=}")
      NOTE_SET=1
      ;;
    *) die "unexpected argument '$control_arg'" ;;
  esac
done
if [ -n "$control_want_value" ]; then
  [ "$control_want_value" = note_file ] && die "--note-file requires a value"
  die "--$control_want_value requires a value"
fi

if [ "$VERB" != relaunch ]; then
  [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] && [ "$NOTE_SET" = 0 ] \
    || die "--harness, --model, --effort, and --note apply to 'relaunch' only"
fi
[ "$HARNESS_SET" = 0 ] || [ -n "$NEW_HARNESS" ] || die "--harness requires a non-empty value"
[ "$MODEL_SET" = 0 ] || [ -n "$NEW_MODEL" ] || die "--model requires a non-empty value"
[ "$EFFORT_SET" = 0 ] || [ -n "$NEW_EFFORT" ] || die "--effort requires a non-empty value"
jg_account_hook control-validate "$VERB" || exit 1
case "$NEW_EFFORT" in
  ''|default|low|medium|high|xhigh|max|ultra) ;;
  *) die "--effort must be one of default, low, medium, high, xhigh, max, ultra" ;;
esac

# --- exact task-id resolution ----------------------------------------------

case "$RAW_ID" in
  *:*) die "'$RAW_ID' is an explicit backend endpoint; jg-control accepts an exact task id only, so a lifecycle command can never land on an endpoint this home does not own" ;;
esac
if ! jg_task_id_creation_valid "$RAW_ID"; then
  die "'$RAW_ID' is not a valid task id"
fi
ID=$RAW_ID
# Supervision lease guard: lifecycle control is overlap territory between the
# two Pi supervision actors; refuse while the OTHER actor holds this task's
# live lease (contract: bin/jg-lease-lib.sh; no-op in homes without leases).
# shellcheck source=bin/jg-lease-lib.sh
. "$SCRIPT_DIR/jg-lease-lib.sh"
jg_lease_guard "$ID" "lifecycle control (jg-control)"
CONTROL_LOCK="$STATE/.control-$ID.lock"
trap control_cleanup EXIT
jg_lock_try_acquire "$CONTROL_LOCK" \
  || die "another lifecycle action is already running for task $ID"
CONTROL_LOCK_HELD=1
# do_exit runs in a command substitution. That subshell does not run this
# EXIT trap, so the parent has to hold the path the trap removes. Set it
# only once the lock is held: a process that loses the lock runs the same
# trap, and would remove the file the lock holder is reading.
JG_COMPOSER_DIALOG_SINK=$STATE/$ID.composer-dialog
META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  case "$RAW_ID" in
    jg-*)
      if [ -f "$STATE/${RAW_ID#jg-}.meta" ]; then
        die "'$RAW_ID' is a window label, not a task id; pass the exact task id '${RAW_ID#jg-}'"
      fi
      ;;
  esac
  die "no task '$ID' in $STATE (jg-control resolves an exact task id only)"
fi

# A remotely placed squad_lead records its endpoint on ANOTHER host, so every
# postcondition this plane verifies - the agent-state classification, the busy
# verdict, the endpoint's existence - would be read here for an endpoint that
# does not live here. Endpoint validation already refuses such a record, since
# `window=remote:<id>` can never match a local backend's required shape, so
# nothing can be delivered to a wrong endpoint either way. What that refusal
# cannot say is WHY, and "malformed metadata" is the wrong thing to tell an
# operator about a correctly configured remote route. Name the placement
# instead, using the same `remote_host` signal bin/jg-send.sh routes on.
if [ -n "$(jg_meta_get "$META" remote_host)" ]; then
  die "task $ID is a remotely placed squad_lead on $(jg_meta_get "$META" remote_host); its agent runs outside this home, so no lifecycle action here could verify that it interrupted, stopped, or came back. Drive its lifecycle on that host, and reconcile it through the squad_lead recovery path rather than this plane"
fi

jg_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$JG_BACKEND_VALIDATED_BACKEND
T=$JG_BACKEND_VALIDATED_TARGET
LABEL="jg-$ID"
RECORDED_HARNESS=$(jg_meta_get "$META" harness)
KIND=$(jg_meta_get "$META" kind)
WT=$(jg_meta_get "$META" worktree)
[ -n "$KIND" ] || KIND=ship

HARNESS=$(jg_control_harness_family "$RECORDED_HARNESS") \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; jg-control refuses to guess an interrupt key or exit command"
jg_control_harness_supported "$HARNESS" \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; jg-control refuses to guess an interrupt key or exit command"

jg_backend_validate "$BACKEND" || exit 1

# --- shared helpers ---------------------------------------------------------

agent_state() {
  jg_backend_agent_state "$BACKEND" "$T" "$META" "$ID"
}

busy_verdict() {
  jg_busy_classify_meta "$META" "$ID" "$STATE"
}

# wait_agent_state <wanted...> <timeout>: poll until agent_state prints one of
# the wanted values. Prints the final observed state; returns 0 on a match.
wait_agent_state() {  # <timeout> <wanted>...
  local timeout=$1 state want elapsed=0
  shift
  while :; do
    state=$(agent_state)
    for want in "$@"; do
      if [ "$state" = "$want" ]; then
        printf '%s' "$state"
        return 0
      fi
    done
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf '%s' "$state"
  return 1
}

require_state_verified_backend() {  # <verb>
  jg_control_backend_state_verified "$BACKEND" && return 0
  die "task $ID runs on the $BACKEND backend, which has no recovery-grade agent-state classifier, so '$1' cannot prove the agent actually stopped; refusing rather than reporting an unproven transition as done"
}

# refuse_blocking_prompt: the screen is a dialog a confirming Enter would
# answer. Name it and stop. Do not type Escape or an option: both dismiss
# or choose.
refuse_blocking_prompt() {  # <dialog-name>
  die "task $ID is blocked on a prompt: $1. Refusing to type Enter into it."
}

# rendered_matches <ere>: whether any row of the visible viewport matches.
# An unreadable viewport is a no, so every caller treats it as missing proof.
rendered_matches() {  # <ere>
  local screen
  screen=$(jg_backend_visible_capture "$BACKEND" "$T" "$LABEL" 2>/dev/null) || return 1
  printf '%s\n' "$screen" | grep -Eq -- "$1"
}

# wait_rendered <ere> <timeout>: poll the viewport until a row matches.
wait_rendered() {  # <ere> <timeout>
  local elapsed=0 step
  step=$(awk -v p="$POLL" 'BEGIN{printf "%s", (p < 0.1 ? p : 0.1)}')
  while :; do
    rendered_matches "$1" && return 0
    awk -v e="$elapsed" -v t="$2" 'BEGIN{exit !(e < t)}' || return 1
    sleep "$step"
    elapsed=$(awk -v e="$elapsed" -v p="$step" 'BEGIN{printf "%.3f", e + p}')
  done
}

# dismiss_interrupt_hazard <key> <ere>: after the presses, close a surface a
# mistimed press opened (Devin's revert picker) with one more key, before
# anything else can be typed into it. Sets INTERRUPT_HAZARD.
dismiss_interrupt_hazard() {  # <key> <ere>
  local key=$1 hazard=$2 gap
  gap=$(jg_control_interrupt_press_gap "$HARNESS")
  sleep "$gap"
  rendered_matches "$hazard" || return 0
  jg_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
    || die "task $ID shows the $HARNESS revert picker after its interrupt, and the $key that closes it was not delivered; nothing else was typed. Close it with $key, never Enter, before any other action"
  sleep "$gap"
  ! rendered_matches "$hazard" \
    || die "task $ID still shows the $HARNESS revert picker after one $key; nothing else was typed. Close it with $key, never Enter, before any other action"
  INTERRUPT_HAZARD=dismissed
}

# send_interrupt_keys: deliver the harness's interrupt key the verified number
# of times, then the composer-clear key when the adapter needs one. Refuses
# before sending anything when the backend cannot deliver either key, because
# an interrupt that cancels the turn but leaves the restored prompt in the
# composer would make the next submitted line concatenate onto it. An adapter
# with an arm signal (jg_control_interrupt_arm_signal) gets each later press
# only after the viewport proves the first one armed a running turn, and never
# sooner than its press gap; without that proof INTERRUPT_ARMED=no and no
# further press is sent. Its hazard surface is then closed before returning.
send_interrupt_keys() {
  local key repeat clear arm hazard gap i=0
  key=$(jg_control_interrupt_key "$HARNESS")
  repeat=$(jg_control_interrupt_repeat "$HARNESS")
  clear=$(jg_control_interrupt_clear_key "$HARNESS")
  arm=$(jg_control_interrupt_arm_signal "$HARNESS")
  hazard=$(jg_control_interrupt_hazard_signal "$HARNESS")
  gap=$(jg_control_interrupt_press_gap "$HARNESS")
  jg_control_backend_supports_key "$BACKEND" "$key" \
    || die "harness $HARNESS interrupts with $key, which the $BACKEND backend cannot deliver; refusing to send a different key"
  [ -z "$clear" ] || jg_control_backend_supports_key "$BACKEND" "$clear" \
    || die "harness $HARNESS needs $clear to clear its composer after an interrupt, which the $BACKEND backend cannot deliver; refusing to leave the cancelled prompt where the next submitted line would concatenate onto it"
  [ -z "$arm$hazard" ] || jg_backend_visible_capture_supported "$BACKEND" \
    || die "harness $HARNESS must see its screen between interrupt presses, because a repeated $key on an idle agent opens its revert picker, and the $BACKEND backend has no verified viewport read; refusing to press blind"
  INTERRUPT_ARMED=yes
  INTERRUPT_HAZARD=none
  while [ "$i" -lt "$repeat" ]; do
    jg_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
      || die "interrupt key $key was not delivered to task $ID on $BACKEND"
    i=$((i + 1))
    [ "$i" -lt "$repeat" ] || break
    sleep "$gap"
    if [ -n "$arm" ] && ! wait_rendered "$arm" "$ARM_WAIT"; then
      INTERRUPT_ARMED=no
      break
    fi
  done
  [ -z "$hazard" ] || dismiss_interrupt_hazard "$key" "$hazard"
  [ -z "$clear" ] || jg_backend_send_key "$BACKEND" "$T" "$clear" "$LABEL" \
    || die "interrupt key $key reached task $ID, but $clear did not, so its composer still holds the cancelled prompt; clear it before the next lifecycle action"
}

prepare_interrupt_ack() {
  INTERRUPT_ACK_SOURCE=$(jg_control_interrupt_ack_source "$HARNESS")
  INTERRUPT_ACK_LOG=
  INTERRUPT_ACK_RUN=
  case "$INTERRUPT_ACK_SOURCE" in
    muse-session-terminal)
      INTERRUPT_ACK_LOG=$(jg_busy_muse_session_log "$STATE" "$ID" 2>/dev/null || true)
      [ -n "$INTERRUPT_ACK_LOG" ] || return 0
      INTERRUPT_ACK_RUN=$(jg_busy_muse_active_run_id "$INTERRUPT_ACK_LOG" 2>/dev/null || true)
      ;;
  esac
}

interrupt_cancel_claim() {
  local elapsed=0 terminal=
  case "$INTERRUPT_ACK_SOURCE:$INTERRUPT_ACK_RUN" in
    muse-session-terminal:?*) ;;
    *) printf 'unconfirmed'; return 0 ;;
  esac
  while :; do
    terminal=$(jg_busy_muse_run_terminal "$INTERRUPT_ACK_LOG" "$INTERRUPT_ACK_RUN" 2>/dev/null || true)
    case "$terminal" in
      cancelled) printf 'confirmed'; return 0 ;;
      ?*) printf 'unconfirmed'; return 0 ;;
    esac
    awk -v e="$elapsed" -v t="$SETTLE_WAIT" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf 'unconfirmed'
}

# deliver_interrupt: deliver and observe the strongest adapter-owned
# cancellation claim available after delivery. `not-running` means an armed
# adapter's first press rendered no running turn, so nothing was cancelled; a
# dismissed revert picker is reported beside the claim.
deliver_interrupt() {
  local cancel devin_gen=
  # Devin does not emit Stop for cancellation. Capture this incarnation before
  # keys, then invalidate its state conservatively rather than claiming idle.
  if [ "$HARNESS" = devin ]; then
    devin_gen=$(jg_busy_current_gen "$STATE" "$ID" 2>/dev/null || true)
  fi
  prepare_interrupt_ack
  send_interrupt_keys
  if [ "$INTERRUPT_ARMED" = no ]; then
    cancel=not-running
  else
    cancel=$(interrupt_cancel_claim)
    if [ "$HARNESS" = devin ] && [ -n "$devin_gen" ]; then
      "$SCRIPT_DIR/jg-busy-event.sh" apply "$STATE" "$ID" unknown \
        --gen "$devin_gen" --source jg-interrupt --event interrupt >/dev/null 2>&1 || true
    fi
  fi
  [ "$INTERRUPT_HAZARD" = none ] || cancel="$cancel revert-picker=$INTERRUPT_HAZARD"
  printf '%s' "$cancel"
}

verify_interrupt_running() {
  local proof after
  jg_backend_target_exists "$BACKEND" "$T" "$LABEL" \
    || die "task $ID's endpoint disappeared while interrupting it; no further control action is safe"
  proof=endpoint
  if jg_control_backend_state_verified "$BACKEND"; then
    # An interrupt cancels a turn; it must never have stopped the agent. This
    # is the postcondition that separates a landed interrupt from an accident.
    after=$(agent_state)
    [ "$after" = alive ] \
      || die "task $ID's agent is '$after' after its interrupt key; an interrupt must leave the agent running"
    proof='agent-alive'
  fi
  printf '%s' "$proof"
}

do_interrupt() {
  local proof cancel
  cancel=$(deliver_interrupt) || return $?
  proof=$(verify_interrupt_running) || return $?
  printf '%s cancel=%s' "$proof" "$cancel"
}

# Drop busy_gen from the task record when it still names <gen>.
# jg-busy-event.sh owns the sidecar and the record; jg_backlog_atomic_transition
# publish owns the task record. Clearing the line inside the busy writer would
# take the task-record lock that teardown and spawn already hold; the busy
# writer is their child process, so it would wait on a live holder that is
# itself waiting on the child, and neither would ever proceed.
clear_retired_meta_busy_gen() {  # <gen>
  local gen=$1 meta="$STATE/$ID.meta" lock tmp current line
  [ -n "$gen" ] || return 0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  if ! declare -F jg_backlog_atomic_transition >/dev/null 2>&1; then
    # shellcheck source=bin/jg-tasks-axi-lib.sh
    . "$SCRIPT_DIR/jg-tasks-axi-lib.sh"
    # shellcheck source=bin/jg-backlog-transition-lib.sh
    . "$SCRIPT_DIR/jg-backlog-transition-lib.sh"
  fi
  lock=$(jg_meta_lock_path "$meta") || return 1
  jg_lock_acquire_wait "$lock"
  current=$(jg_meta_get "$meta" busy_gen)
  if [ "$current" != "$gen" ]; then
    jg_lock_release "$lock"
    return 0
  fi
  tmp=$(mktemp "$STATE/.$ID.meta.retire.XXXXXX") || {
    jg_lock_release "$lock"
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      busy_gen=*) ;;
      *)
        printf '%s\n' "$line" >> "$tmp" || {
          rm -f "$tmp"
          jg_lock_release "$lock"
          return 1
        }
        ;;
    esac
  done < "$meta" || {
    rm -f "$tmp"
    jg_lock_release "$lock"
    return 1
  }
  if ! jg_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$STATE"; then
    rm -f "$tmp"
    jg_lock_release "$lock"
    return 1
  fi
  jg_lock_release "$lock"
}

retire_busy_incarnation() {
  local gen=
  if [ -f "$STATE/$ID.busy-gen" ]; then
    gen=$(jg_busy_current_gen "$STATE" "$ID" 2>/dev/null || true)
    if [ -n "$gen" ] \
      && "$SCRIPT_DIR/jg-busy-event.sh" retire "$STATE" "$ID" --gen "$gen" >/dev/null 2>&1; then
      clear_retired_meta_busy_gen "$gen" || true
    fi
  fi
}

# Complete only an adapter-owned exact exit confirmation, with fresh endpoint
# and agent proof immediately before Enter. Never choose the detach option.
complete_exit_confirmation() {
  local screen confirmation dialog
  [ "$HARNESS" = claude ] || return 1
  screen=$(jg_backend_visible_capture "$BACKEND" "$T" "$LABEL" 2>/dev/null) || return 1
  confirmation=$(jg_control_exit_confirmation "$HARNESS" "$screen")
  case "$confirmation" in
    none) return 1 ;;
    refuse)
      dialog=$(jg_composer_blocking_dialog "$screen") \
        && refuse_blocking_prompt "$dialog"
      die "task $ID shows an unsupported or ambiguous exit confirmation; refusing lifecycle input" ;;
    stop)
      jg_backend_validate_task_endpoint "$META" "$ID" || return 2
      [ "$(agent_state)" = alive ] || die "task $ID no longer proves a live agent; refusing exit confirmation"
      # Re-read after the identity checks so a changed selection is refused.
      screen=$(jg_backend_visible_capture "$BACKEND" "$T" "$LABEL" 2>/dev/null) || return 2
      [ "$(jg_control_exit_confirmation "$HARNESS" "$screen")" = stop ] \
        || die "task $ID exit confirmation changed before delivery; refusing Enter"
      jg_backend_send_key "$BACKEND" "$T" Enter "$LABEL" || return 2
      return 0 ;;
  esac
}

wait_exit_stopped() {
  local elapsed=0 state rc confirmed=${1:-0} retries=1 screen content
  while :; do
    state=$(agent_state)
    [ "$state" != dead ] || return 0
    if [ "$state" = alive ] && [ "$confirmed" = 0 ]; then
      rc=0
      complete_exit_confirmation || rc=$?
      case "$rc" in
        0) confirmed=1 ;;
        1)
          # A slash popup can consume the first Enter. Retry only while the
          # current composer still proves this exact exit command, never on
          # an opaque modal or an unrelated pending draft.
          if [ "$HARNESS" = claude ] && [ "$retries" -lt "$EXIT_RETRIES" ]; then
            screen=$(jg_backend_visible_capture "$BACKEND" "$T" "$LABEL" 2>/dev/null) || screen=
            content=$(jg_composer_extract_selected_content 'styled=0
cursor=0
identity=0' "$screen" 2>/dev/null) || content=
            if [ "${content//[$' \t\r\n']/}" = /exit ]; then
              jg_backend_validate_task_endpoint "$META" "$ID" || return 1
              [ "$(agent_state)" = alive ] || return 1
              jg_backend_send_key "$BACKEND" "$T" Enter "$LABEL" || return 1
              retries=$((retries + 1))
            fi
          fi ;;
        *) return 1 ;;
      esac
    fi
    awk -v e="$elapsed" -v t="$EXIT_WAIT" 'BEGIN{exit !(e < t)}' || return 1
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
}

# do_exit: stop the running agent, preserving endpoint and worktree. Prints
# `already-stopped`, `endpoint-gone`, or `stopped`.
do_exit() {
  local state cmd hazard verdict composer_state cancel absence submit_retries=$EXIT_RETRIES interrupt_result=not-needed dialog clear_key
  require_state_verified_backend exit
  state=$(agent_state)
  case "$state" in
    dead)
      printf 'already-stopped'
      return 0
      ;;
    alive) ;;
    missing)
      # `missing` on its own is not a finding about the endpoint: it conflates
      # "destroyed" with "unreachable from this seat". Route it through the
      # control plane's one absence proof - the same one the relaunch gate uses
      # - and report what that proof actually established, never more.
      absence=$(jg_control_endpoint_absence_verdict "$BACKEND" "$T")
      case "${absence%%$'\t'*}" in
        gone)
          # Proven gone, so the agent that lived in it went with it: exit's
          # postcondition already holds and there is nothing to send. Its own
          # outcome rather than `already-stopped`, because the endpoint this
          # verb normally preserves did not survive. The worktree and every
          # uncommitted change are untouched, and `relaunch` re-creates the
          # endpoint from here.
          printf 'endpoint-gone'
          return 0
          ;;
        dead)
          # The endpoint was only unreachable and is there after all, holding
          # no agent - a herdr pane whose session server was merely stopped is
          # the common case. Nothing is gone, so this is the ordinary
          # already-stopped outcome.
          printf 'already-stopped'
          return 0
          ;;
        alive)
          # The agent came back with its endpoint. Fall through to the ordinary
          # alive path: interrupt if busy, then the harness's exit command.
          ;;
        *)
          die "task $ID's endpoint $T reads 'missing', but ${absence#*$'\t'}; exit will not claim an agent stopped at an address it cannot trust, nor send lifecycle input to one"
          ;;
      esac
      ;;
    *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle command into an unattributed endpoint" ;;
  esac
  # A previous guarded exit may already have opened the supported modal.
  local confirmation_rc=0
  complete_exit_confirmation || confirmation_rc=$?
  case "$confirmation_rc" in
    0)
      wait_exit_stopped 1 || die "task $ID exit confirmation delivered but agent stop remains unconfirmed"
      retire_busy_incarnation
      printf 'stopped'
      return 0 ;;
    1) ;;
    *) die "task $ID exit confirmation could not be delivered safely" ;;
  esac
  # A resumed Claude can wait at a startup gate with no composer yet. Any
  # answer, Escape included, is stored as the project's decision (Escape at the
  # imports gate records "No, disable", which then blocks every trust
  # registration for that project), so close the endpoint instead: the agent
  # has loaded nothing yet, and relaunch re-creates the endpoint.
  local gate_screen
  gate_screen=$(jg_backend_visible_capture "$BACKEND" "$T" "$LABEL" 2>/dev/null) || gate_screen=
  if [ "$(jg_control_startup_gate "$HARNESS" "$gate_screen")" = gate ]; then
    jg_backend_validate_task_endpoint "$META" "$ID" >/dev/null \
      || die "task $ID's endpoint no longer validates; refusing to close it"
    jg_backend_kill "$BACKEND" "$T" "$(jg_meta_get "$META" zellij_tab_id)" "jg-$ID" \
      || die "task $ID waits at a Claude startup dialog and its endpoint $T could not be closed; answer nothing there and close it by hand"
    retire_busy_incarnation
    printf 'endpoint-gone'
    return 0
  fi
  # A busy agent is interrupted first before the exit command is submitted.
  case "$(busy_verdict)" in
    busy*)
      cancel=$(deliver_interrupt) || return $?
      state=$(agent_state)
      case "$state" in
        dead)
          retire_busy_incarnation
          printf 'stopped'
          return 0
          ;;
        alive) interrupt_result="delivered verified=agent-alive cancel=$cancel" ;;
        missing) die "task $ID's recorded endpoint disappeared after interrupt delivery, so exit cannot prove whether the agent stopped" ;;
        *) die "task $ID's endpoint reads '$state' after interrupt delivery rather than a positively classified state; exit cannot prove whether the agent stopped" ;;
      esac
      ;;
  esac
  cmd=$(jg_control_exit_command "$HARNESS")
  hazard=$(jg_control_interrupt_hazard_signal "$HARNESS")
  if [ -n "$hazard" ] && rendered_matches "$hazard"; then
    die "task $ID shows the $HARNESS revert picker, where typed text becomes a search and Enter reverts file changes; refusing to type the $cmd exit command. Close it with $(jg_control_interrupt_key "$HARNESS"), never Enter, then retry '$VERB'"
  fi
  : > "$JG_COMPOSER_DIALOG_SINK" \
    || die "task $ID's dialog check could not be recorded"
  composer_state=$(jg_backend_composer_state "$BACKEND" "$T" "$LABEL" 2>/dev/null) \
    || composer_state=unknown
  # The classify that filled the sink ran in a subshell, so read the file
  # rather than a function that subshell sourced.
  if [ -s "${JG_COMPOSER_DIALOG_SINK:-}" ]; then
    dialog=$(cat "$JG_COMPOSER_DIALOG_SINK")
    refuse_blocking_prompt "$dialog"
  fi
  # The refusal names the working recovery so the next operator clears or
  # submits the pending text instead of looping on interrupt: Enter submits it
  # through the data plane, and the harness's clear key (when the capability
  # table above names one) discards it.
  clear_key=$(jg_control_interrupt_clear_key "$HARNESS" 2>/dev/null || true)
  case "$composer_state" in
    empty) ;;
    pending)
      if [ -n "$clear_key" ]; then
        die "task $ID's composer visibly holds pending text; refusing to type the $cmd exit command because it would concatenate onto that text. Submit it with 'jg-send.sh $ID --key Enter', or clear it with 'jg-send.sh $ID --key $clear_key', then retry '$VERB'."
      else
        die "task $ID's composer visibly holds pending text; refusing to type the $cmd exit command because it would concatenate onto that text. Submit it with 'jg-send.sh $ID --key Enter', or clear the composer, then retry '$VERB'."
      fi
      ;;
    *)
      if [ -n "$clear_key" ]; then
        die "task $ID's composer state is '$composer_state', not proven empty; refusing to type the $cmd exit command because it could concatenate onto existing text. Clear the composer with 'jg-send.sh $ID --key $clear_key', then retry '$VERB'."
      else
        die "task $ID's composer state is '$composer_state', not proven empty; refusing to type the $cmd exit command because it could concatenate onto existing text. Clear the composer, then retry '$VERB'."
      fi
      ;;
  esac
  # The submit verdict is NOT the postcondition here: a successful exit command
  # destroys the composer the verdict is read from, so a post-exit read can
  # legitimately report anything. Only a hard transport failure aborts; the
  # authoritative proof is the agent-state wait below. The retried Enter still
  # matters, because a slash command opens a completion popup on some TUIs that
  # swallows the first Enter.
  # Claude retries belong to the guarded wait: a modal is not a composer.
  [ "$HARNESS" != claude ] || submit_retries=1
  verdict=$(jg_backend_send_text_submit "$BACKEND" "$T" "$cmd" "$submit_retries" "$POLL" 1.2 "$LABEL") \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  [ "$verdict" != send-failed ] \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  # The submitting Enter can open a picker. Only the fork's separately
  # verified exact stop dialog may be confirmed by the guarded control path;
  # every other recognised picker keeps upstream's refusal. A dead agent may
  # leave the same text behind; that is not a prompt still waiting.
  if [ -s "${JG_COMPOSER_DIALOG_SINK:-}" ]; then
    dialog=$(cat "$JG_COMPOSER_DIALOG_SINK")
    if [ "$(agent_state)" != dead ]; then
      complete_exit_confirmation || refuse_blocking_prompt "$dialog"
      wait_exit_stopped 1 || die "task $ID exit confirmation delivered but agent stop remains unconfirmed"
    fi
  fi
  wait_exit_stopped || {
    state=$(agent_state)
    # A submit can return before any read sees the picker: a native busy
    # verdict needs no composer read, and a cleared composer can be read
    # before the picker renders. Read the screen once more here.
    : > "$JG_COMPOSER_DIALOG_SINK" || true
    jg_backend_composer_state "$BACKEND" "$T" "$LABEL" >/dev/null 2>&1 || true
    if [ -s "$JG_COMPOSER_DIALOG_SINK" ]; then
      refuse_blocking_prompt "$(cat "$JG_COMPOSER_DIALOG_SINK")"
    fi
    die "exit-delivered $ID interrupt=$interrupt_result exit-command=delivered agent-state=$state exit=unconfirmed; the agent did not stop within ${EXIT_WAIT}s"
  }
  # The incarnation is over: retire its busy wiring so no stale record or
  # orphaned generation survives the agent that produced it.
  retire_busy_incarnation
  printf 'stopped'
}

# --- transactional relaunch -------------------------------------------------
#
# The transaction's durable record is state/<id>.control-relaunch, with the
# prior metadata and brief preserved beside it. Every failure path runs through
# relaunch_rollback (an EXIT trap, so a refusal raised deep inside a shared
# helper is covered too) and leaves either the pre-relaunch durable record or a
# concrete, named partial state - never a task whose record claims an agent
# that is not running.

JOURNAL="$STATE/$ID.control-relaunch"
META_PRIOR="$JOURNAL.meta-prior"
BRIEF_PRIOR="$JOURNAL.brief-prior"
NOTE_FILE="$JOURNAL.note"
RELAUNCH_META_PUBLISHED=0
RELAUNCH_AGENT_CONFIRMED=0
RELAUNCH_TX=
RELAUNCH_BRIEF=
PRIOR_HARNESS=$HARNESS
PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
CONFIG_HARNESS=
CONFIG_MODEL=
CONFIG_EFFORT=
PRIOR_MODEL=
PRIOR_EFFORT=
TARGET_HARNESS=$HARNESS
TARGET_MODEL=
TARGET_EFFORT=

journal_write() {  # <phase> [extra-line]...
  local phase=$1
  shift
  if {
    echo "v1"
    echo "task=$ID"
    echo "phase=$phase"
    echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "backend=$BACKEND"
    echo "endpoint=$T"
    echo "worktree=$WT"
    echo "kind=$KIND"
    echo "from_harness=$PRIOR_RECORDED_HARNESS"
    echo "from_model=$PRIOR_MODEL"
    echo "from_effort=$PRIOR_EFFORT"
    echo "to_harness=$TARGET_HARNESS"
    echo "to_model=$TARGET_MODEL"
    echo "to_effort=$TARGET_EFFORT"
    local line
    for line in "$@"; do
      echo "$line"
    done
  } > "$JOURNAL.tmp" && mv -f "$JOURNAL.tmp" "$JOURNAL"; then
    RELAUNCH_PHASE=$phase
    return 0
  fi
  return 1
}

relaunch_rollback() {
  local state
  [ "$RELAUNCH_ACTIVE" = 1 ] || return 0
  [ "$RELAUNCH_PHASE" != complete ] || return 0
  RELAUNCH_ACTIVE=0
  case "$RELAUNCH_PHASE" in
    checkpoint|noted)
      # The old agent was never touched. Restore the instructions byte-exact so
      # a refused relaunch leaves nothing behind.
      if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
        cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
      fi
      journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored" || true
      echo "error: relaunch of $ID was refused before its agent was touched; nothing changed" >&2
      ;;
    stopping)
      state=$(agent_state 2>/dev/null || printf unknown)
      case "$state" in
        alive)
          if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
            cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
          fi
          journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-agent-alive" || true
          echo "error: relaunch of $ID failed while stopping the old agent, which is still running; its original instructions were restored" >&2
          ;;
        dead)
          journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept-agent-dead" || true
          echo "error: $ID's agent stopped but relaunch did not reach replacement launch; no agent is running, and its work plus progress note are preserved at $WT" >&2
          ;;
        *)
          # The old agent was NOT proven stopped, so no replacement is coming
          # and the agent that may still be reading these instructions is the
          # original one. The note exists to brief a replacement; leaving it in
          # a possibly-live agent's brief would be an unrequested edit to a
          # running task. Restore byte-exact, exactly as the alive case does.
          if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
            cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
          fi
          journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-agent-state-$state" || true
          echo "error: relaunch of $ID failed while stopping the old agent and its state is '$state', so it was not proven stopped; its original instructions were restored and the durable record was retained for recovery" >&2
          ;;
      esac
      ;;
    exited|launching)
      if [ "$RELAUNCH_AGENT_CONFIRMED" = 1 ]; then
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-agent-confirmed" || true
        echo "error: $ID's replacement is running on $TARGET_HARNESS, but transaction completion could not be persisted; its published record was retained for reconciliation" >&2
      elif [ "$RELAUNCH_META_PUBLISHED" = 1 ] \
         || { [ -n "$RELAUNCH_TX" ] \
              && [ "$(jg_meta_get "$META" control_relaunch_tx)" = "$RELAUNCH_TX" ]; }; then
        # The launch owner published the new incarnation's record. Leaving it
        # in place is the honest state: the task is now recorded on the new
        # harness with no agent confirmed, which is exactly what recovery
        # reconciles. Rewriting it back to the old harness would be a second,
        # worse inaccuracy.
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-record-kept" || true
        echo "error: $ID was relaunched on $TARGET_HARNESS but no running agent could be confirmed; its work is preserved at $WT" >&2
      else
        journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept" || true
        echo "error: $ID's agent was stopped but the replacement did not launch; no agent is running, and its work plus the recorded progress note are preserved at $WT" >&2
      fi
      ;;
  esac
  return 0
}

resolve_relaunch_profile() {
  PRIOR_HARNESS=$HARNESS
  PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
  PRIOR_MODEL=$(jg_meta_get "$META" model)
  PRIOR_MODEL_MISSING=0
  [ -n "$PRIOR_MODEL" ] || PRIOR_MODEL_MISSING=1
  PRIOR_EFFORT=$(jg_meta_get "$META" effort)
  [ -n "$PRIOR_MODEL" ] || PRIOR_MODEL=default
  [ -n "$PRIOR_EFFORT" ] || PRIOR_EFFORT=default
  if [ "$HARNESS_SET" = 0 ] \
     && [ "$PRIOR_RECORDED_HARNESS" != "$PRIOR_HARNESS" ]; then
    die "task $ID records harness '$PRIOR_RECORDED_HARNESS', whose original launch command cannot be reconstructed from its recorded basename; relaunching without --harness would substitute the canonical adapter '$PRIOR_HARNESS' for the command actually running. Pass an explicit --harness to choose the replacement runtime deliberately"
  fi
  CONFIG_HARNESS=
  CONFIG_MODEL=
  CONFIG_EFFORT=
  if [ "$KIND" = squad_lead ]; then
    # A squad_lead's harness, model, and effort are a durable configured pin
    # that every respawn re-resolves (the squad-lead-provisioning contract), so
    # a relaunch with no explicit harness picks up a newly configured one
    # instead of freezing whatever this incarnation happens to run. Operators
    # and scouts deliberately do NOT resolve config here: their harness comes
    # from juggernaut's own dispatch-profile judgment at intake, and silently
    # re-resolving it would bypass that consultation.
    CONFIG_HARNESS=$("$SCRIPT_DIR/jg-harness.sh" squad_lead "$ID") || return 1
    CONFIG_MODEL=$("$SCRIPT_DIR/jg-harness.sh" squad-lead-model "$ID") || return 1
    CONFIG_EFFORT=$("$SCRIPT_DIR/jg-harness.sh" squad-lead-effort "$ID") || return 1
    case "$CONFIG_EFFORT" in
      ''|low|medium|high|xhigh|max|ultra) ;;
      *)
        echo "warning: config/squad-lead-harness effort token '$CONFIG_EFFORT' is not one of low, medium, high, xhigh, max, ultra; ignoring" >&2
        CONFIG_EFFORT=
        ;;
    esac
  fi
  if [ "$HARNESS_SET" = 1 ]; then
    jg_control_harness_supported "$NEW_HARNESS" \
      || die "'$NEW_HARNESS' is not a verified harness; jg-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$NEW_HARNESS
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    jg_control_harness_supported "$CONFIG_HARNESS" \
      || die "the configured squad_lead harness '$CONFIG_HARNESS' is not verified; jg-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$CONFIG_HARNESS
  else
    TARGET_HARNESS=$PRIOR_HARNESS
  fi
  # The launch owner refuses an adapter that cannot run this task's kind, but it
  # is only reached after the old agent has been stopped. Asking the same
  # capability table here keeps that refusal on the pre-stop side of the
  # transaction, where nothing has changed yet.
  jg_control_harness_supports_kind "$TARGET_HARNESS" "$KIND" \
    || die "'$TARGET_HARNESS' is not verified to run a $KIND task, so relaunching $ID onto it would stop the running agent for a launch that must be refused; choose an adapter verified for this kind"
  # A model or effort chosen for the previous harness does not transfer to a
  # different one, so an explicit harness change resets both axes unless the
  # caller names them too.
  MODEL_FROM_PIN=0
  if [ "$MODEL_SET" = 1 ]; then
    TARGET_MODEL=$NEW_MODEL
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_MODEL=${CONFIG_MODEL:-default}
    # A pin that names no model clears the axis: jg-spawn must be told so
    # explicitly, or its same-harness relaunch reloads the stored model.
    MODEL_FROM_PIN=1
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_MODEL=$PRIOR_MODEL
  else
    TARGET_MODEL=default
  fi
  if [ "$MODEL_SET" = 0 ] && [ "$MODEL_FROM_PIN" = 0 ] && [ "$PRIOR_MODEL_MISSING" = 1 ] && [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ] && [ "$TARGET_MODEL" = default ]; then
    die "task $ID has no stored model for $TARGET_HARNESS; refusing to relaunch on its default model; pass --model explicitly"
  fi
  if [ "$EFFORT_SET" = 1 ]; then
    TARGET_EFFORT=$NEW_EFFORT
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_EFFORT=${CONFIG_EFFORT:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_EFFORT=$PRIOR_EFFORT
  else
    TARGET_EFFORT=default
  fi
  if [ "$TARGET_EFFORT" = ultra ]; then
    "$SCRIPT_DIR/jg-harness.sh" validate-native-effort "$TARGET_HARNESS" "$TARGET_MODEL" "$TARGET_EFFORT" || return 1
  fi
  # The launch owner applies this home's worker account pin too, but only after
  # the old agent has been stopped, so a pin that no longer resolves or is
  # signed out must refuse here, while nothing has changed yet.
  local account_model=$TARGET_MODEL
  [ "$account_model" != default ] || account_model=
  jg_worker_account_select "$TARGET_HARNESS" "${JG_CONFIG_OVERRIDE:-$JG_HOME/config}" \
    "$account_model" "$TARGET_HARNESS" >/dev/null || return 1
  jg_account_hook relaunch-pre "$TARGET_HARNESS" "${JG_CONFIG_OVERRIDE:-$JG_HOME/config}" "$account_model" "$(jg_meta_get "$META" account)" "$PRIOR_MODEL" "$ID" || return 1
  # Likewise config/crew-exclude-tools: a malformed file, or a replacement
  # runtime that cannot hide the listed tools, refuses here, before the old
  # agent stops. SquadLead agents are not covered.
  if [ "$KIND" != squad_lead ]; then
    jg_exclude_tools_check "$TARGET_HARNESS" 0 "${JG_CONFIG_OVERRIDE:-$JG_HOME/config}" >/dev/null || return 1
  fi
}

# safe_checkpoint: prove, before anything is stopped, that the work a relaunch
# must preserve is actually there and recoverable afterwards. Fills
# CHECKPOINT_LINES with the journal lines describing what it proved, and
# refuses outright when any of it cannot be established.
CHECKPOINT_LINES=()
safe_checkpoint() {
  local wt_real wt_top wt_top_real head head_ref head_ref_status status_output dirty children marker child_meta
  CHECKPOINT_LINES=()
  [ -n "$WT" ] || die "task $ID has no recorded worktree; refusing to relaunch without a recorded local copy to preserve"
  [ -d "$WT" ] || die "task $ID's recorded worktree $WT is missing; refusing to relaunch and lose track of its work"
  wt_real=$(cd "$WT" 2>/dev/null && pwd -P) || die "task $ID's recorded worktree $WT cannot be resolved"
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) \
    || die "task $ID's recorded worktree $WT is not a git worktree; refusing to relaunch without a checkout whose unlanded work can be accounted for"
  wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P) || wt_top_real=$wt_top
  [ "$wt_real" = "$wt_top_real" ] \
    || die "task $ID's recorded worktree $WT is not a worktree root (root is $wt_top); refusing to relaunch against an ambiguous checkout"
  if jg_slot_record_owner "$WT" "$STATE" "$META"; then
    die "task $ID's recorded worktree $WT is also recorded by task $JG_SLOT_RECORD_OWNER_ID as its $JG_SLOT_RECORD_OWNER_FIELD; refusing to relaunch two agents into one copy. Reconcile which record is stale (bin/jg-crew-state.sh $ID $JG_SLOT_RECORD_OWNER_ID)"
  elif [ $? -eq 2 ]; then
    die "cannot prove task $ID's worktree $WT is free of other task records: $JG_LOCAL_JUGGERNAUT_ERROR; refusing to relaunch"
  fi
  if head=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null); then
    :
  elif head_ref=$(git -C "$WT" symbolic-ref -q HEAD 2>/dev/null); then
    if git -C "$WT" show-ref --verify --quiet "$head_ref" 2>/dev/null; then
      die "task $ID's worktree HEAD exists but cannot be resolved; refusing to relaunch from an unreadable checkout"
    else
      head_ref_status=$?
      [ "$head_ref_status" -eq 1 ] \
        || die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
      head=unborn
    fi
  else
    die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
  fi
  status_output=$(git -C "$WT" status --porcelain 2>/dev/null) \
    || die "task $ID's worktree status cannot be inspected; refusing to relaunch without accounting for local changes"
  if [ -n "$status_output" ]; then
    dirty=yes
  else
    dirty=no
  fi
  CHECKPOINT_LINES+=("worktree_head=$head" "worktree_dirty=$dirty")
  if [ "$KIND" = squad_lead ]; then
    # A squad_lead's own operators outlive its relaunch: they run in their own
    # endpoints, and the relaunched squad_lead reconciles them from its home's
    # durable records at startup. The checkpoint proves those records are
    # readable BEFORE the agent stops, so a relaunch can never strand child
    # work behind an unreadable home.
    marker=$(cat "$(jg_compat_marker "$WT")" 2>/dev/null || true)
    [ "$marker" = "$ID" ] \
      || die "task $ID's home $WT is not marked as its own seeded squad_lead home (marker: ${marker:-none}); refusing to relaunch"
    # Do not walk state/ with find(1): watcher scratch files can vanish
    # mid-scan and make find fail even when every child *.meta is readable.
    [ -d "$WT/state" ] && [ -r "$WT/state" ] && [ -x "$WT/state" ] \
      || die "squad_lead $ID's home has no readable state directory, so its child work cannot be accounted for; refusing to relaunch"
    children=0
    for child_meta in "$WT/state"/*.meta; do
      if [ ! -e "$child_meta" ] && [ ! -L "$child_meta" ]; then
        continue
      fi
      if [ ! -f "$child_meta" ] || [ -L "$child_meta" ] \
         || ! cat "$child_meta" >/dev/null 2>&1; then
        die "squad_lead $ID's child record $child_meta is not a readable regular file; refusing to relaunch"
      fi
      children=$((children + 1))
    done
    CHECKPOINT_LINES+=("children=$children")
  fi
}

# record_note: put the required progress note somewhere durable, and - for a
# ship or scout, whose only record of the interrupted reasoning is the
# conversation about to be discarded - into the instructions the replacement
# actually reads. A squad_lead's charter is a durable standing document and is
# never rewritten: a squad_lead reconciles its own home's records at startup,
# so the note stays parent-side audit evidence.
record_note() {
  local stamp
  [ -n "$NOTE" ] || return 0
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' "$NOTE" > "$NOTE_FILE"
  case "$KIND" in
    ship|scout)
      cp -p "$RELAUNCH_BRIEF" "$BRIEF_PRIOR" \
        || die "could not preserve task $ID's instructions before recording the progress note"
      {
        echo
        echo "## Progress note ($stamp)"
        echo
        echo "This task was relaunched. Continue from here; the local copy and every"
        echo "uncommitted change are exactly as the previous worker left them."
        echo
        echo "First, check your instruction inbox: list $STATE/$ID.inbox/*.msg, act on"
        echo "each message in numeric order, then mv each handled file into"
        echo "$STATE/$ID.inbox/handled/. A steer sent before the relaunch survives there."
        echo
        printf '%s\n' "$NOTE"
      } >> "$RELAUNCH_BRIEF" \
        || die "could not append the progress note to task $ID's instructions"
      ;;
  esac
}

do_relaunch() {
  local exit_result state note_line
  local -a spawn_args

  require_state_verified_backend relaunch
  resolve_relaunch_profile

  case "$KIND" in
    ship|scout)
      RELAUNCH_BRIEF="$DATA/$ID/brief.md"
      [ -f "$RELAUNCH_BRIEF" ] \
        || die "task $ID has no instructions at $RELAUNCH_BRIEF; refusing to relaunch a worker with nothing to work from"
      [ "$NOTE_SET" = 1 ] && [ -n "$NOTE" ] \
        || die "relaunch of a $KIND task requires --note (or --note-file): the replacement worker inherits the local copy but none of the conversation, so it must be told what happened"
      ;;
    squad_lead)
      # The charter in the squad_lead's own home is its instruction source and
      # stays untouched.
      RELAUNCH_BRIEF=
      ;;
    *)
      die "task $ID records kind '$KIND', which has no defined relaunch shape"
      ;;
  esac

  if [ -n "$NOTE" ]; then
    note_line="note_file=$NOTE_FILE"
  else
    note_line="note=none"
  fi
  # jg-spawn admits the launch on host memory too, but only after the agent is
  # stopped; asking first leaves the running agent untouched on a refusal.
  "$SCRIPT_DIR/jg-jev-mem-guard.sh" --config "${JG_CONFIG_OVERRIDE:-$JG_HOME/config}/host-memory" \
    --admit "$ID" --state "$STATE" >&2 \
    || die "relaunch of $ID refused before its agent was touched: host memory is under pressure; retry once it eases"
  safe_checkpoint
  cp -p "$META" "$META_PRIOR" || die "could not preserve task $ID's durable record before relaunching"
  RELAUNCH_ACTIVE=1
  journal_write checkpoint "${CHECKPOINT_LINES[@]}" "$note_line"

  record_note
  journal_write noted "${CHECKPOINT_LINES[@]}" "$note_line"

  jg_account_hook relaunch-commit "$TARGET_HARNESS" "${JG_CONFIG_OVERRIDE:-$JG_HOME/config}" "$(jg_meta_get "$META" account)" || return 1
  journal_write stopping "${CHECKPOINT_LINES[@]}" "$note_line"
  exit_result=$(do_exit)
  journal_write exited "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"

  # The launch owner (jg-spawn --relaunch) clears the previous incarnation's
  # per-task harness wiring before arming the new one, so nothing to do here.
  RELAUNCH_TX="${BASHPID:-$$}.$(date -u +%Y%m%dT%H%M%SZ).$RANDOM"
  journal_write launching "${CHECKPOINT_LINES[@]}" "$note_line" "relaunch_tx=$RELAUNCH_TX"
  spawn_args=("$ID" --relaunch --harness "$TARGET_HARNESS")
  if [ "$TARGET_MODEL" != default ] || [ "$MODEL_SET" = 1 ] || [ "$MODEL_FROM_PIN" = 1 ]; then
    spawn_args+=(--model "$TARGET_MODEL")
  fi
  [ "$TARGET_EFFORT" = default ] || spawn_args+=(--effort "$TARGET_EFFORT")
  jg_account_hook spawn-args
  if JG_CONTROL_RELAUNCH_TX="$RELAUNCH_TX" \
      "$SCRIPT_DIR/jg-spawn.sh" "${spawn_args[@]}" >/dev/null; then
    RELAUNCH_META_PUBLISHED=1
    # $T was resolved from the record before the launch. When the recorded
    # endpoint was gone, the launch owner created a fresh one and republished
    # the record pointing at it, so every postcondition below must be read from
    # the endpoint the task now HAS, not the one it had. Re-resolving through
    # the same shared validation is what makes that safe: a record that no
    # longer passes it refuses here rather than leaving this transaction
    # polling an address nothing owns.
    # stdout is dropped (it is only the resolved target), but the refusal on
    # stderr names the exact row that failed - and in this one branch the record
    # was just rewritten by the launch owner, so that row is the whole
    # diagnostic. Let it through rather than dying with nothing to act on.
    if jg_backend_validate_task_endpoint "$META" "$ID" >/dev/null \
       && [ -n "$JG_BACKEND_VALIDATED_TARGET" ]; then
      T=$JG_BACKEND_VALIDATED_TARGET
    else
      die "the replacement agent for $ID was launched, but task $ID's republished record no longer passes endpoint validation (the refusal above names the row), so this transaction cannot say which endpoint to confirm it on; reconcile $META before any further control action"
    fi
  else
    [ "$(jg_meta_get "$META" control_relaunch_tx)" != "$RELAUNCH_TX" ] \
      || RELAUNCH_META_PUBLISHED=1
    die "the replacement agent for $ID could not be launched on $TARGET_HARNESS"
  fi

  state=$(wait_agent_state "$LAUNCH_WAIT" alive) || {
    die "the replacement agent for $ID did not come up within ${LAUNCH_WAIT}s (endpoint reads '$state')"
  }
  RELAUNCH_AGENT_CONFIRMED=1

  journal_write complete "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"
  RELAUNCH_ACTIVE=0
  echo "relaunched $ID harness=$TARGET_HARNESS from=$PRIOR_RECORDED_HARNESS model=$TARGET_MODEL effort=$TARGET_EFFORT backend=$BACKEND endpoint=$T worktree=$WT"
}

# --- verbs ------------------------------------------------------------------

case "$VERB" in
  interrupt)
    state=$(agent_state)
    case "$state" in
      alive) ;;
      unverified)
        # No recovery-grade classifier on this backend. Interrupt is
        # non-destructive and its endpoint-existence postcondition is still
        # real, so it proceeds - the printed proof names exactly what was
        # verified rather than implying more.
        ;;
      dead|missing) die "no agent is running at task $ID's recorded endpoint (state: $state); there is nothing to interrupt" ;;
      *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle key into an unattributed endpoint" ;;
    esac
    proof=$(do_interrupt)
    echo "interrupt-delivered $ID harness=$HARNESS backend=$BACKEND verified=$proof"
    ;;
  exit)
    result=$(do_exit)
    # Every outcome that proves the agent stopped records its epoch, so the
    # sentinel's reconcile leaves this lane down until a spawn newer than it.
    case "$result" in
      stopped|already-stopped|endpoint-gone)
        printf '%s\n' "$(date +%s)" >"$STATE/$ID.exit" || die "task $ID stopped, but its exit record could not be written" ;;
    esac
    echo "$result $ID harness=$HARNESS backend=$BACKEND endpoint=$T worktree=$WT"
    ;;
  relaunch)
    # Parked-home guard (core/parked-homes): a parked squad_lead
    # home gets no relaunch. The shim answers not parked when the feature is absent.
    # shellcheck source=bin/jg-parked-homes-lib.sh
    . "$SCRIPT_DIR/jg-parked-homes-lib.sh"
    jg_parked_refuse_meta "$META" "$ID" relaunch || exit 1
    do_relaunch
    ;;
esac
