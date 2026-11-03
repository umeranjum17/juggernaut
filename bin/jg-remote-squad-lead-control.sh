#!/usr/bin/env bash
# Host-local lifecycle control for the remote squad_lead home selected by jg-on.
#
# Usage:
#   jg-remote-squad-lead-control.sh launch <id> <harness> <model|-> <effort|-> herdr [traceparent]
#   jg-remote-squad-lead-control.sh relaunch <id> <harness> <model|default|-> <effort|default|->
#   jg-remote-squad-lead-control.sh state <id>
#   jg-remote-squad-lead-control.sh route <id>
#   jg-remote-squad-lead-control.sh send <id> <message> [fire-and-forget]
#   jg-remote-squad-lead-control.sh key <id> <key>
#   jg-remote-squad-lead-control.sh capture <id> [lines]
#   jg-remote-squad-lead-control.sh observe <id>
#   jg-remote-squad-lead-control.sh sync <id> [<parent-commit>]
#   jg-remote-squad-lead-control.sh update <id>
#   jg-remote-squad-lead-control.sh retire <id> [--force]
#
# Remote placement ends here, but the squad-lead agent always runs on the
# Herdr backend in the dedicated jg-remote session, so launch refuses any other
# selection rather than reading this home's config/backend. The interactive
# default session remains for the user's work.
# jg-spawn/jg-send/jg-teardown keep owning the local endpoint mechanics.
# The home's own workers keep their ordinary backend selection.
# bin/jg-remote-doctor.sh owns that host's readiness for Herdr.
# docs/remote-squad-leads.md owns why.
#
# With <parent-commit>, sync follows the PARENT PRIMARY's default-branch commit,
# which the parent resolves on its own checkout and passes in, so a remote home
# tracks the primary exactly like a local one instead of stopping at whatever
# this host's Juggernaut copy happens to hold. Omitting <parent-commit> targets
# this host's own code-root HEAD instead, which is what /resupply wants
# after it has refreshed that
# code root from origin. Because this home is a standalone clone, the target
# commit is imported here first and the fast-forward itself is the shared one in
# bin/jg-ff-lib.sh, so the clean, ancestry, and branch guards have a single owner.
# A private parent-route state directory stores only the remote squad_lead
# agent's endpoint record; the home's own
# state/*.meta remains reserved for workers the squad_lead supervises.
# Retirement closes only this squad_lead's panes or workspace and never
# stops jg-remote or removes a sibling squad_lead's workspace or panes.
#
# Relaunch is not a second lifecycle implementation: it runs the ORDINARY local
# control plane here, because from this host the mate is a plain local
# squad_lead. cmd_relaunch below owns why the parent must hand it the profile.
# It ends by printing the same route block `route` prints, so a caller that
# invoked it directly (rather than through bin/jg-remote-squad-lead-relaunch.sh,
# which reads this block to keep the parent's own record in sync) still gets
# the confirmed identity.
#
# The optional launch traceparent is the per-task W3C trace-context carrier the
# PARENT home resolved for this squad_lead; this host only delivers it to the
# pane, and jg-spawn validates it (bin/jg-trace-context-lib.sh). Omitting it is
# the default-off path. print_route echoes the carrier the endpoint actually
# holds, including for an already-alive endpoint that was not relaunched, so the
# parent records the identity the agent really received rather than an intent.
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
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET_HOME=${JG_HOME:?JG_HOME is required}
CONTROL_STATE="$TARGET_HOME/state/parent-route"
CONTROL_DATA="$TARGET_HOME/data/.parent-route"
REMOTE_HERDR_SESSION=jg-remote

# shellcheck source=bin/jg-backend.sh
. "$SCRIPT_DIR/jg-backend.sh"
# shellcheck source=bin/jg-ff-lib.sh
. "$SCRIPT_DIR/jg-ff-lib.sh"
# shellcheck source=bin/jg-pending-reply-lib.sh
. "$SCRIPT_DIR/jg-pending-reply-lib.sh"
# shellcheck source=bin/jg-task-inbox-lib.sh
. "$SCRIPT_DIR/jg-task-inbox-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
validate_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) die "invalid squad_lead id: $1" ;; esac; }

validate_home() { # <id> [allow-absent]
  local id=$1 allow_absent=${2:-no} marker
  if [ ! -e "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] && [ "$allow_absent" = yes ]; then return 2; fi
  [ -d "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] || die "remote squad_lead home is unavailable or unsafe"
  [ -f "$(jg_compat_marker "$TARGET_HOME")" ] && [ ! -L "$(jg_compat_marker "$TARGET_HOME")" ] \
    || die "remote home is not a seeded squad_lead home"
  marker=$(cat "$(jg_compat_marker "$TARGET_HOME")")
  [ "$marker" = "$id" ] || die "remote home belongs to $marker, not $id"
  [ -f "$TARGET_HOME/AGENTS.md" ] && [ -d "$TARGET_HOME/bin" ] || die "remote home is not a Juggernaut checkout"
}

meta_path() { printf '%s/%s.meta\n' "$CONTROL_STATE" "$1"; }

remote_endpoint_load() {
  local id=$1 herdr_session
  REMOTE_ENDPOINT_ERROR=
  REMOTE_ENDPOINT_META=$(meta_path "$id")
  if ! jg_backend_validate_task_endpoint "$REMOTE_ENDPOINT_META" "$id" 2>/dev/null; then
    REMOTE_ENDPOINT_ERROR="remote squad_lead $id endpoint metadata is invalid; refusing access until it is explicitly migrated"
    return 1
  fi
  REMOTE_ENDPOINT_BACKEND=$JG_BACKEND_VALIDATED_BACKEND
  REMOTE_ENDPOINT_TARGET=$JG_BACKEND_VALIDATED_TARGET
  if [ "$REMOTE_ENDPOINT_BACKEND" != herdr ]; then
    REMOTE_ENDPOINT_ERROR="remote squad_lead $id endpoint is recorded on backend '$REMOTE_ENDPOINT_BACKEND', expected 'herdr'; refusing access until it is explicitly migrated"
    return 1
  fi
  herdr_session=$(jg_backend_meta_exact_value "$REMOTE_ENDPOINT_META" herdr_session 2>/dev/null || true)
  if [ "$herdr_session" != "$REMOTE_HERDR_SESSION" ]; then
    REMOTE_ENDPOINT_ERROR="remote squad_lead $id endpoint is recorded in Herdr session '${herdr_session:-missing}', expected '$REMOTE_HERDR_SESSION'; refusing access until it is explicitly migrated"
    return 1
  fi
  case "$REMOTE_ENDPOINT_TARGET" in
    "$REMOTE_HERDR_SESSION":?*) ;;
    *)
      REMOTE_ENDPOINT_ERROR="remote squad_lead $id endpoint target '$REMOTE_ENDPOINT_TARGET' is outside Herdr session '$REMOTE_HERDR_SESSION'; refusing access until it is explicitly migrated"
      return 1
      ;;
  esac
}

remote_endpoint_require() {
  remote_endpoint_load "$1" || die "$REMOTE_ENDPOINT_ERROR"
}

state_value() { # <id>; prints recovery-grade state
  local id=$1 meta
  meta=$(meta_path "$id")
  [ -f "$meta" ] && [ ! -L "$meta" ] || { printf 'missing\n'; return 0; }
  if ! remote_endpoint_load "$id"; then
    printf 'error: %s\n' "$REMOTE_ENDPOINT_ERROR" >&2
    printf 'unverified\n'
    return 0
  fi
  jg_backend_agent_state "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" 2>/dev/null || printf 'unreadable\n'
}

print_route() { # <id>
  local id=$1 harness model effort traceparent
  remote_endpoint_require "$id"
  harness=$(jg_meta_get "$REMOTE_ENDPOINT_META" harness)
  model=$(jg_meta_get "$REMOTE_ENDPOINT_META" model)
  effort=$(jg_meta_get "$REMOTE_ENDPOINT_META" effort)
  traceparent=$(jg_meta_get "$REMOTE_ENDPOINT_META" traceparent)
  printf 'schema=jg-remote-squad-lead-control.v1\n'
  printf 'backend=%s\n' "$REMOTE_ENDPOINT_BACKEND"
  printf 'target=%s\n' "$REMOTE_ENDPOINT_TARGET"
  printf 'herdr_session=%s\n' "$REMOTE_HERDR_SESSION"
  printf 'harness=%s\n' "$harness"
  printf 'model=%s\n' "$model"
  printf 'effort=%s\n' "$effort"
  [ -z "$traceparent" ] || printf 'traceparent=%s\n' "$traceparent"
}

cmd_route() {
  local id=$1 meta
  validate_id "$id"
  validate_home "$id"
  meta=$(meta_path "$id")
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    die "remote squad_lead has no endpoint metadata"
  fi
  print_route "$id"
}

cmd_launch() {
  local id=$1 harness=$2 model=$3 effort=$4 selected_backend=$5 traceparent=${6:-}
  local current meta out herdr_session

  validate_id "$id"
  validate_home "$id"
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor) ;;
    *) die "unverified remote squad_lead harness: $harness" ;;
  esac
  case "$effort" in -|low|medium|high|xhigh|max|ultra) ;; *) die "invalid remote squad_lead effort: $effort" ;; esac
  if [ "$effort" = ultra ]; then
    "$SCRIPT_DIR/jg-harness.sh" validate-native-effort "$harness" "$model" "$effort" || return 1
  fi
  # Herdr is required on this host, not merely preferred: its server belongs to
  # the GUI login session, so the endpoint survives every SSH disconnection that
  # a remote route depends on. bin/jg-remote-doctor.sh is the readiness owner.
  case "$selected_backend" in herdr) ;; *) die "a remote squad_lead runs only on the herdr backend, not '$selected_backend'" ;; esac
  mkdir -p "$CONTROL_STATE" "$CONTROL_DATA"
  meta=$(meta_path "$id")
  if [ -f "$meta" ]; then
    remote_endpoint_require "$id"
    current=$(jg_backend_agent_state "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" 2>/dev/null || printf 'unreadable\n')
    case "$current" in
      alive)
        print_route "$id"
        return 0
        ;;
      dead)
        jg_backend_kill "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" 2>/dev/null \
          || die "could not remove the confirmed agent-less endpoint"
        ;;
      missing) ;;
      *) die "remote endpoint state is $current; refusing duplicate launch" ;;
    esac
  fi
  # The parent owns both convergence legs before it asks for this launch: it
  # already fast-forwarded this home to ITS primary commit and pushed inherited
  # local material, so this spawn must not redo either against this host's own
  # Juggernaut copy, which would target the wrong checkout.
  ARGS=("$id" "$TARGET_HOME" --squad-lead --harness "$harness" --backend "$selected_backend")
  [ "$model" = - ] || ARGS+=(--model "$model")
  [ "$effort" = - ] || ARGS+=(--effort "$effort")
  [ -z "$traceparent" ] || ARGS+=(--traceparent "$traceparent")
  if ! out=$(HERDR_SESSION="$REMOTE_HERDR_SESSION" JG_HOME="$JG_ROOT" JG_ROOT_OVERRIDE="$JG_ROOT" \
    JG_STATE_OVERRIDE="$CONTROL_STATE" JG_DATA_OVERRIDE="$CONTROL_DATA" \
    JG_CONFIG_OVERRIDE="$TARGET_HOME/config" JG_SKIP_SQUAD_LEAD_INHERIT=1 \
    JG_SKIP_SQUAD_LEAD_SYNC=1 \
    "$SCRIPT_DIR/jg-spawn.sh" "${ARGS[@]}" 2>&1); then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    die "remote host-local squad_lead launch failed"
  fi
  [ -f "$meta" ] || die "remote launch returned without endpoint metadata"
  herdr_session=$(jg_meta_get "$meta" herdr_session)
  [ "$herdr_session" = "$REMOTE_HERDR_SESSION" ] \
    || die "remote launch recorded Herdr session '${herdr_session:-missing}', expected '$REMOTE_HERDR_SESSION'"
  print_route "$id"
}

# Restart the squad-lead agent this host runs, by executing the ORDINARY local
# control plane here. From this host's point of view the mate is a plain local
# squad_lead: its endpoint record under the private parent-route state directory
# was written by a host-local jg-spawn and carries no remote_host= field, so
# bin/jg-control.sh's remote refusal never fires, and every checkpoint, journal,
# rollback, and postcondition that plane owns applies unchanged. This verb is the
# transport hop, not a second implementation.
#
# harness/model/effort come from the PARENT and are passed explicitly, because
# config/squad-lead-harness is deliberately not inherited into a squad_lead home:
# the copy on this host is a different home's file, so letting the control plane
# re-resolve it here would silently drift the mate onto another runtime. `default`
# explicitly clears an absent parent pin; `-` remains its compatibility spelling.
cmd_relaunch() {
  local id=$1 harness=$2 model=$3 effort=$4
  local -a control_args

  validate_id "$id"
  validate_home "$id"
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor) ;;
    *) die "unverified remote squad_lead harness: $harness" ;;
  esac
  case "$effort" in -|default|low|medium|high|xhigh|max|ultra) ;; *) die "invalid remote squad_lead effort: $effort" ;; esac
  case "$model" in *[[:space:]]*) die "invalid remote squad_lead model: $model" ;; esac
  if [ "$effort" = ultra ]; then
    "$SCRIPT_DIR/jg-harness.sh" validate-native-effort "$harness" "$model" "$effort" || return 1
  fi
  remote_endpoint_require "$id"
  [ "$model" != - ] || model=default
  [ "$effort" != - ] || effort=default
  control_args=("$id" relaunch --harness "$harness" --model "$model" --effort "$effort")
  # The same launch-boundary facts cmd_launch establishes: the endpoint lives in
  # the dedicated jg-remote session, and the parent already owns both convergence
  # legs, so the host-local spawn must not re-sync or re-inherit against this
  # host's own Juggernaut copy.
  HERDR_SESSION="$REMOTE_HERDR_SESSION" JG_HOME="$JG_ROOT" JG_ROOT_OVERRIDE="$JG_ROOT" \
    JG_STATE_OVERRIDE="$CONTROL_STATE" JG_DATA_OVERRIDE="$CONTROL_DATA" \
    JG_CONFIG_OVERRIDE="$TARGET_HOME/config" JG_SKIP_SQUAD_LEAD_INHERIT=1 \
    JG_SKIP_SQUAD_LEAD_SYNC=1 \
    "$SCRIPT_DIR/jg-control.sh" "${control_args[@]}"
  # A parent tracking this route needs the identity the relaunch actually
  # produced, not the one it asked for, so it can republish its own record the
  # same way cmd_launch's caller already does. Reading it back from the
  # endpoint's own republished metadata - rather than trusting these argv
  # values - is what makes that record correct even when relaunch resolved
  # "default" against a configured pin this call never saw.
  print_route "$id"
}

cmd_send() {
  local id=$1 message=$2 delivery_mode=${3:-} rec ring_rc=0 meta meta_lock
  validate_id "$id"
  [ -z "$delivery_mode" ] || [ "$delivery_mode" = fire-and-forget ] || die "invalid send delivery mode"
  validate_home "$id"
  meta=$(meta_path "$id")
  meta_lock=$(jg_meta_lock_path "$meta") || die "remote squad_lead metadata lock path is invalid"
  jg_task_inbox_lock_acquire "$meta_lock" \
    || die "remote squad_lead endpoint metadata could not be locked for final delivery validation"
  if ! remote_endpoint_load "$id"; then
    jg_lock_release "$meta_lock"
    die "$REMOTE_ENDPOINT_ERROR"
  fi
  # A remote steer is delivered by durable record, never by typing its payload
  # into the pane: write it into this squad_lead's host-local steering inbox,
  # then ring the constant self-describing doorbell into the recorded pane,
  # best-effort (bin/jg-task-inbox-lib.sh owns the record and doorbell). The
  # write is idempotent - re-running the same request after an ambiguous
  # transport failure lands on the existing record instead of a duplicate - so
  # the parent may safely repeat this leg. Exit 0 once the record durably
  # exists; no ring outcome changes it, because the parent transport owns any
  # retry or reply-tracking policy from here.
  if ! rec=$(jg_task_inbox_write_idempotent "$CONTROL_STATE" "$id" "$message" "$delivery_mode"); then
    jg_lock_release "$meta_lock"
    die "steering-inbox record could not be written under $CONTROL_STATE/$id.inbox"
  fi
  jg_lock_release "$meta_lock"
  case "$rec" in
    */handled/*)
      # The dedup landed on a record the worker already acknowledged: the
      # steer was delivered and acted on, so there is nothing to announce.
      printf 'notice: this steer was already delivered and acknowledged at %s; nothing re-rung\n' "$rec" >&2
      return 0
      ;;
  esac
  jg_task_inbox_ring "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "$rec" "jg-$id" || ring_rc=$?
  case "$ring_rc" in
    1) printf "notice: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at %s. To ring now, submit the pending text with '%s key %s Enter' (or clear the composer); the next ring then lands.\n" "$rec" "jg-remote-squad-lead-control.sh" "$id" >&2 ;;
    2) printf 'notice: doorbell did not reach %s; the steer is durably recorded at %s\n' "$REMOTE_ENDPOINT_TARGET" "$rec" >&2 ;;
    3) printf 'notice: doorbell not typed because the agent in %s has exited; the steer is durably recorded at %s for recovery\n' "$REMOTE_ENDPOINT_TARGET" "$rec" >&2 ;;
  esac
}

cmd_key() {
  local id=$1 key=$2
  validate_id "$id"
  validate_home "$id"
  remote_endpoint_require "$id"
  JG_HOME="$TARGET_HOME" JG_ROOT_OVERRIDE="$JG_ROOT" JG_STATE_OVERRIDE="$TARGET_HOME/state" \
    "$SCRIPT_DIR/jg-send.sh" "$REMOTE_ENDPOINT_TARGET" --key "$key"
}

cmd_capture() {
  local id=$1 lines=${2:-20}
  validate_id "$id"
  validate_home "$id"
  case "$lines" in ''|*[!0-9]*|0) die "capture line count must be positive" ;; esac
  [ "$lines" -le 100 ] || die "capture line count exceeds 100"
  remote_endpoint_require "$id"
  jg_backend_capture "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "$lines" "jg-$id" | head -c 65536
}

cmd_observe() {
  local id=$1 harness
  validate_id "$id"
  validate_home "$id"
  remote_endpoint_require "$id"
  harness=$(jg_meta_get "$REMOTE_ENDPOINT_META" harness)
  jg_pending_reply_backend_observation "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "jg-$id" "$harness"
  printf '\n'
}

# Make <commit> readable in this home's own object store without moving any other
# checkout. Ordered by cost: already present, then this host's Juggernaut copy (a
# read-only fetch of that one commit, which never advances that copy's HEAD), then
# the home's own origin for that one commit. No pack transport beyond those two.
import_home_commit() { # <home> <commit>
  local home=$1 commit=$2
  if git -C "$home" cat-file -e "$commit^{commit}" 2>/dev/null; then return 0; fi
  if git -C "$home" fetch --quiet --no-tags -- "$JG_ROOT" "$commit" 2>/dev/null \
    && git -C "$home" cat-file -e "$commit^{commit}" 2>/dev/null; then
    return 0
  fi
  if git -C "$home" remote get-url origin >/dev/null 2>&1 \
    && git -C "$home" fetch --quiet --no-tags -- origin "$commit" 2>/dev/null \
    && git -C "$home" cat-file -e "$commit^{commit}" 2>/dev/null; then
    return 0
  fi
  return 1
}

cmd_sync() {
  local id=$1 commit report out
  validate_id "$id"
  validate_home "$id"
  if [ "$#" -ge 2 ]; then
    commit=$2
    case "$commit" in *[!0-9a-f]*) die "sync target must be a full 40-character commit id" ;; esac
    [ "${#commit}" -eq 40 ] || die "sync target must be a full 40-character commit id"
  else
    commit=$(git -C "$JG_ROOT" rev-parse HEAD 2>/dev/null) || die "remote code root HEAD is unreadable"
  fi
  import_home_commit "$TARGET_HOME" "$commit" \
    || die "remote home could not import $commit from this host's Juggernaut copy or the home's origin; run /resupply to refresh this host's copy, or push that commit first"
  # ff_target publishes its verdict in FF_STATUS, so it must run in THIS shell.
  report=$(mktemp "${TMPDIR:-/tmp}/jg-remote-sync.XXXXXX") || die "cannot stage the sync report"
  ff_target "$TARGET_HOME" "remote home" "$commit" yes yes "$id" "$TARGET_HOME/state" > "$report" 2>&1
  out=$(cat "$report")
  rm -f "$report"
  case "$FF_STATUS" in
    # instr= names the watched instruction paths this advance changed, with no
    # spaces so the whole result stays one parseable line. The parent needs it to
    # decide whether the running agent must reload; an older parent ignores the
    # suffix, and an older HOST omits it, which a parent must read as unknown
    # rather than as "nothing changed".
    updated) printf 'synced: %s instr=%s\n' "$commit" "$(printf '%s' "$FF_INSTR" | tr -d ' ')" ;;
    current) printf 'current: %s\n' "$commit" ;;
    *) die "remote squad_lead home sync skipped: ${out#remote home: skipped: }" ;;
  esac
}

cmd_update() {
  local id=$1 update_out root_status
  validate_id "$id"
  validate_home "$id"
  if ! update_out=$(JG_HOME="$JG_ROOT" JG_ROOT_OVERRIDE="$JG_ROOT" \
    "$SCRIPT_DIR/jg-update.sh" 2>&1); then
    [ -z "$update_out" ] || printf '%s\n' "$update_out" >&2
    die "remote code root update failed"
  fi
  root_status=$(printf '%s\n' "$update_out" | grep '^juggernaut:' | tail -1)
  case "$root_status" in
    'juggernaut: updated '*|'juggernaut: already current'*) ;;
    *)
      [ -z "$update_out" ] || printf '%s\n' "$update_out" >&2
      die "remote code root did not complete a safe origin update"
      ;;
  esac
  cmd_sync "$id"
}

cmd_retire() {
  local id=$1 force=${2:-} rc
  validate_id "$id"
  validate_home "$id" yes || rc=$?
  if [ "${rc:-0}" -eq 2 ]; then
    printf 'already-retired: %s\n' "$id"
    return 0
  fi
  [ -z "$force" ] || [ "$force" = --force ] || usage
  remote_endpoint_require "$id"
  JG_HOME="$TARGET_HOME" JG_ROOT_OVERRIDE="$JG_ROOT" JG_STATE_OVERRIDE="$TARGET_HOME/state" \
    JG_CONFIG_OVERRIDE="$TARGET_HOME/config" "$SCRIPT_DIR/jg-guard.sh" || true
  if [ -n "$force" ]; then
    JG_HOME="$JG_ROOT" JG_ROOT_OVERRIDE="$JG_ROOT" \
      JG_STATE_OVERRIDE="$CONTROL_STATE" JG_DATA_OVERRIDE="$CONTROL_DATA" \
      JG_CONFIG_OVERRIDE="$TARGET_HOME/config" JG_TEARDOWN_GUARD_DONE=1 \
      "$SCRIPT_DIR/jg-teardown.sh" "$id" --force
  else
    JG_HOME="$JG_ROOT" JG_ROOT_OVERRIDE="$JG_ROOT" \
      JG_STATE_OVERRIDE="$CONTROL_STATE" JG_DATA_OVERRIDE="$CONTROL_DATA" \
      JG_CONFIG_OVERRIDE="$TARGET_HOME/config" JG_TEARDOWN_GUARD_DONE=1 \
      "$SCRIPT_DIR/jg-teardown.sh" "$id"
  fi
}

case "${1:-}" in
  launch) shift; [ "$#" -ge 5 ] && [ "$#" -le 6 ] || usage; cmd_launch "$@" ;;
  relaunch) shift; [ "$#" -eq 4 ] || usage; cmd_relaunch "$@" ;;
  state) shift; [ "$#" -eq 1 ] || usage; validate_id "$1"; validate_home "$1"; state_value "$1" ;;
  route) shift; [ "$#" -eq 1 ] || usage; cmd_route "$1" ;;
  send) shift; [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage; cmd_send "$@" ;;
  key) shift; [ "$#" -eq 2 ] || usage; cmd_key "$@" ;;
  capture) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_capture "$@" ;;
  observe) shift; [ "$#" -eq 1 ] || usage; cmd_observe "$@" ;;
  sync) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_sync "$@" ;;
  update) shift; [ "$#" -eq 1 ] || usage; cmd_update "$@" ;;
  retire) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
