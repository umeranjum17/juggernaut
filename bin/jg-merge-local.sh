#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the operator's immutable ship branch recorded in
# state/<task-id>.meta ("fm/<id>" for records created before that field existed).
#
# This is juggernaut's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the operator rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
# Usage: jg-merge-local.sh <task-id>
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
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-dod-lib.sh
. "$SCRIPT_DIR/jg-dod-lib.sh"
# shellcheck source=bin/jg-backlog-transition-lib.sh
. "$SCRIPT_DIR/jg-backlog-transition-lib.sh"
if [ "$#" -ne 1 ] || ! jg_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
jg_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $JG_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
"$JG_ROOT/bin/jg-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/jg-lease-lib.sh;
# no-op in homes without a branch actor). This action is deliberately NOT
# relocated under the away-posture record: unlike the PR merge it has no
# record-side grant gate of its own, so a parked main keeps it held for the
# captain's return. This precedes reading the task record, because the wrong
# actor is refused for its role whatever it says.
# shellcheck source=bin/jg-lease-lib.sh
. "$SCRIPT_DIR/jg-lease-lib.sh"
jg_lease_forbid_branch "local-only landing (jg-merge-local)"

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! jg_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $JG_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$JG_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
merge_control_cleanup() {
  [ -z "$MERGE_CONTROL_LOCK" ] || jg_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
jg_lock_acquire_wait "$MERGE_CONTROL_LOCK"
if ! jg_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $JG_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$JG_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/jg-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
  exit 1
fi
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (juggernaut never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the operator rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
hold_status=0
JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/jg-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
case "$hold_status" in
  0)
    echo "error: task $ID is still held for the captain; release it before merging" >&2
    exit 1
    ;;
  1|3) ;;
  *)
    echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
    exit 1
    ;;
esac
candidate=$(git -C "$PROJ" rev-parse --verify "refs/heads/$BRANCH^{commit}")
if declare -F jg_dod_receipt_accept >/dev/null; then jg_dod_receipt_accept "$STATE" "$ID" "$META" "$candidate" >&2 || exit 1; fi
if declare -F jg_dod_design_gate >/dev/null; then jg_dod_design_gate "$STATE" "$ID" "$META" "$candidate" >&2 || exit 1; fi
if declare -F jg_dod_demo_gate >/dev/null; then jg_dod_demo_gate "${JG_CONFIG_OVERRIDE:-$JG_HOME/config}" "$STATE" "$ID" "$META" "$candidate" >&2 || exit 1; fi
if declare -F jg_dod_nav_gate >/dev/null; then jg_dod_nav_gate "$ID" "$META" "$(git -C "$PROJ" log --format=%B "$DEFAULT..$candidate")" >&2 || exit 1; fi
if declare -F jg_dod_merge_gate >/dev/null; then jg_dod_merge_gate "${JG_CONFIG_OVERRIDE:-$JG_HOME/config}" "$JG_HOME" "$ID" "$META" "$candidate" - >&2 || exit 1; fi
if declare -F jg_dod_proof_gate >/dev/null; then jg_dod_proof_gate "$JG_HOME" "$ID" "$candidate" - >&2 || exit 1; fi
merge_status=0
git -C "$PROJ" merge --ff-only "$candidate" >/dev/null || merge_status=$?
jg_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
[ "$merge_status" -eq 0 ] || exit "$merge_status"
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "${JG_CONFIG_OVERRIDE:-$JG_HOME/config}/fleet-ledger" ] || JG_HOME=$JG_HOME JG_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/jg-fleet-ledger.sh" merged "$ID" local || true
# A local-only landing has no PR; the ticket closes here instead of at the next poll.
JG_HOME=$JG_HOME JG_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/jg-ticket.sh" "$ID" --stage "done" --state "done" || true
if [ "$before" != "$after" ] && declare -F jg_merge_post_hook >/dev/null; then jg_merge_post_hook "${JG_CONFIG_OVERRIDE:-$JG_HOME/config}" "$JG_HOME" "$ID" "$META" "$candidate" - >&2; fi
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
