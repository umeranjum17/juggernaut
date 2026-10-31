#!/usr/bin/env bash
# Shared durable, supervisor-facing outcome publication for a confirmed merge.
#
# Both a merge performed by this home and a merge detected by its existing poll
# use this operation, so neither outcome depends on an agent remembering it.
# This operation publishes the poll's local actionable row; the watcher
# immediately delivers that row as observation handling, not a second outcome
# path.
#
# The destination is the home's role, never the caller's choice:
#   - a squad_lead home reports upward on its parent channel, resolved and
#     appended through bin/jg-parent-channel-lib.sh under its channel contract;
#   - a main home reports to the captain through the durable wake queue.
# A poll observed in a squad_lead home also receives a local durable wake after
# the upward write, so the mate can handle its own poll observation.
# No new state file and no new transport are involved.
#
# Normal operation deduplicates the task's latest canonical PR identity through
# the merge-notification marker owned by bin/jg-pr-lib.sh. Main-home wake keys
# also include that PR identity so distinct PRs for a reused task remain
# distinct in queue presentation. The outcome is published before the marker
# is committed, so a failed commit stays eligible for at-least-once retry and
# may rarely duplicate rather than leave a merge silent.
#
# Sourced by bin/jg-pr-merge.sh, bin/jg-watch.sh, and tests. No side effects on
# source beyond its sourced libraries.

_JG_MERGE_OUTCOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-addons-dir-lib.sh
. "$_JG_MERGE_OUTCOME_LIB_DIR/jg-addons-dir-lib.sh"
# shellcheck source=bin/jg-pr-lib.sh
. "$_JG_MERGE_OUTCOME_LIB_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-parent-channel-lib.sh
. "$_JG_MERGE_OUTCOME_LIB_DIR/jg-parent-channel-lib.sh"
# shellcheck source=bin/jg-board-link-lib.sh
# shellcheck disable=SC1091
. "$_JG_MERGE_OUTCOME_LIB_DIR/jg-board-link-lib.sh"

# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
JG_MERGE_OUTCOME_ALREADY_RECORDED=false

# jg_merge_outcome_report <home> <state> <task-id> <pr-url> <origin> [authority]
#
# <origin> says who observed the merge, because that decides whether the
# existing poll path also needs a local wake:
#   self - this home performed the merge.
#   poll - this home's merge poll detected the merge, so the canonical outcome
#          also wakes this home after any upward hop needed by a squad_lead.
# Optional <authority> is away, attended, or external (the retired yolo and
# away-grant values are still accepted for a persisted authority written before
# the words model landed). Away, external, and the retired tags are appended to
# the ledger line; attended remains untagged. The merge entrypoint supplies its
# authority after forge acceptance, while the poll supplies the persisted
# identity-bound value or external when no matching record proves that this
# home authorized the merge.
#
# Returns 0 when the outcome is recorded (or already was), 2 on an invalid
# request, 3 when this home's own role or parent binding cannot be read well
# enough to say where the outcome belongs, and 1 on any other failure to
# record. A caller that has already merged must report a non-zero return rather
# than treat it as success: the merge landed and the record did not.
jg_merge_outcome_report() {  # <home> <state> <task-id> <pr-url> <origin> [authority]
  local home=$1 state=$2 id=$3 url=$4 origin=$5
  local authority=${6-} suffix='' card_link
  local self_rc=0 destination='' line lock status=0
  local provider host path number
  # shellcheck disable=SC2034 # Sourced wake helpers consume these scoped globals.
  local STATE JG_WAKE_QUEUE JG_WAKE_QUEUE_LOCK
  JG_MERGE_OUTCOME_ALREADY_RECORDED=false
  case "$origin" in self|poll) ;; *) return 2 ;; esac
  case "$authority" in
    away|external|yolo|away-grant) suffix=" $authority" ;;
    attended|'') ;;
    *) return 2 ;;
  esac
  jg_pr_task_id_valid "$id" || return 2
  jg_pr_url_parse "$url" || return 2
  provider=$JG_PR_PROVIDER
  host=$JG_PR_HOST
  path=$JG_PR_PATH
  number=$JG_PR_NUMBER
  [ -d "$state" ] && [ ! -L "$state" ] || return 1

  if destination=$(jg_parent_channel_destination "$home" "$state"); then
    line="done [key=merged-$id]: merged $id $JG_PR_URL$suffix"
    if card_link=$(jg_board_link reports "$(jg_board_merge_key "$JG_PR_URL")" 2>/dev/null); then
      line="$line card=$card_link"
    fi
  else
    self_rc=$?
    [ "$self_rc" -eq 1 ] || return 3
    destination=''
  fi

  STATE=$state
  # shellcheck source=bin/jg-wake-lib.sh
  . "$_JG_MERGE_OUTCOME_LIB_DIR/jg-wake-lib.sh"
  lock="$state/$id.pr-poll-merge-notified.lock"
  jg_lock_acquire_wait "$lock" || return 1
  if jg_pr_poll_merge_already_notified "$state" "$id" \
    "$provider" "$host" "$path" "$number"; then
    # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
    JG_MERGE_OUTCOME_ALREADY_RECORDED=true
    jg_lock_release "$lock"
    return 0
  fi

  if [ -n "$destination" ]; then
    jg_parent_channel_append_once "$destination" "$(status_stamp_line "$line")" || status=1
  fi
  if [ "$status" -eq 0 ] && { [ "$origin" = poll ] || [ -z "$destination" ]; }; then
    jg_wake_append check "merged-$id-$JG_PR_URL" \
      "check: merge landed: $id $JG_PR_URL$suffix" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    jg_pr_poll_merge_mark_notified "$state" "$id" \
      "$provider" "$host" "$path" "$number" || status=1
  fi
  jg_lock_release "$lock"
  # Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
  [ ! -e "${JG_CONFIG_OVERRIDE:-$home/config}/fleet-ledger" ] || [ "$status" -ne 0 ] || JG_HOME=$home JG_STATE_OVERRIDE=$state "$_JG_MERGE_OUTCOME_LIB_DIR/jg-fleet-ledger.sh" merged "$id" pr "$JG_PR_URL" || true
  # The ticket closes with the merge and carries the delivered PR, not the link
  # some earlier status line happened to mention.
  [ "$status" -ne 0 ] || JG_HOME=$home JG_STATE_OVERRIDE=$state "$_JG_MERGE_OUTCOME_LIB_DIR/jg-ticket.sh" "$id" --stage "done" --state "done" --pr "$JG_PR_URL" || true
  if [ "$status" -eq 0 ] && declare -F jg_merge_post_hook >/dev/null; then jg_merge_post_hook "${JG_CONFIG_OVERRIDE:-$home/config}" "$home" "$id" "$state/$id.meta" - "$JG_PR_URL" >&2; fi
  # The merge card carries the proof too: a no-op when the post hook filed it, else files it or says what is missing.
  if [ "$status" -eq 0 ] && { [ -e "${JG_CONFIG_OVERRIDE:-$home/config}/post-merge" ] || [ -n "${JG_PROOF_BOARD:-}" ]; }; then
    JG_HOME=$home "$_JG_MERGE_OUTCOME_LIB_DIR/jg-proof-attach.sh" attach merged "$id" --pr "$JG_PR_URL" 2>&1 | sed 's/^/proof: /' >&2 || true
  fi
  # One board alert per proven merge, queued durably when the board is down; it never changes the outcome.
  if [ "$status" -eq 0 ]; then
    JG_HOME=$home JG_STATE_OVERRIDE=$state "$_JG_MERGE_OUTCOME_LIB_DIR/jg-merge-alert.sh" post "$id" --pr "$JG_PR_URL" --authority "${authority:-attended}" 2>&1 | sed 's/^/alert: /' >&2 || true
  fi
  return "$status"
}

# Merge hooks owned by core (the same file bin/jg-dod-lib.sh sources), so
# config/post-merge runs whether or not the merge-card add-on is installed.
# shellcheck source=bin/jg-merge-gate-lib.sh
. "$_JG_MERGE_OUTCOME_LIB_DIR/jg-merge-gate-lib.sh"
# Optional merge-card add-on: defines the same two hooks for homes that install it.
_jg_mo_hooks=$(jg_addon_path "${JG_HOME:-$_JG_MERGE_OUTCOME_LIB_DIR/..}" merge-card/bin/jg-merge-hooks-lib.sh)
# shellcheck source=/dev/null
[ ! -r "$_jg_mo_hooks" ] || . "$_jg_mo_hooks"

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
