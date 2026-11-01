#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# Refuses when bin/jg-dod-lib.sh will not accept the named head as reachable
# outside the worker's disposable copy; in no-mistakes mode a forge-reported
# head is that named head and is already stored on the forge. The optional
# receipts add-on picks the receipt candidate from the verified forge head and
# the gate receives it as a hook argument. The gate also reads a pull request's
# live forge head itself when the worker copy holds no remote-tracking ref for
# it, so a push that opened the PR from outside this copy's ref sync still
# registers.
# The watcher check source is byte-for-byte bin/jg-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL, a GitLab merge request URL, and a Gerrit change URL
# are all accepted, including a merge request or change on a self-hosted
# instance.
# A GitHub pull request the forge reports as a draft is refused, naming the draft
# state and recording and arming nothing: a draft cannot be merged, so a poll armed on it
# would wait for an event that cannot occur while nobody is asked to act.
# Mark the pull request ready for review, then arm again; a lane that keeps a
# draft on purpose declares a wait instead of reporting done. An unreadable
# draft state does not refuse, matching how the head read below is optional.
# bin/jg-pr-merge.sh records through this script with JG_PR_CHECK_MERGE=1 and
# skips this refusal, because its own merge-time draft refusal is authoritative.
# The recorded pr= also frees the task's place in a declared project capacity
# (bin/jg-project-capacity-lib.sh), and a new review-ready PR moves the task's
# ticket to the review stage (bin/jg-ticket.sh). A newly recorded GitHub pull
# request also says on its own page what it is waiting for, through the
# juggernaut/waiting-for commit status bin/jg-pr-lib.sh jg_pr_wait_status
# publishes; bin/jg-pr-merge.sh replaces that line when its gate names another
# wait and clears it before merging.
# --from-status is the watcher's call on every status change: it records the PR
# named by the task's newest status line only when that line is the ship ready
# report its mode gives (jg_dod_should_gate_ship_done) and that PR is not
# already recorded, and otherwise exits 0 having done nothing. The named-head
# gate below still decides, so a refusal records nothing.
# Usage: jg-pr-check.sh <task-id> <pr-url>
#        jg-pr-check.sh --from-status <task-id>
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
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-parent-channel-lib.sh
. "$SCRIPT_DIR/jg-parent-channel-lib.sh"
# shellcheck source=bin/jg-dod-lib.sh
. "$SCRIPT_DIR/jg-dod-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
if [ "$1" = --from-status ]; then
  jg_pr_task_id_valid "$2" || { echo "error: invalid PR check request" >&2; exit 2; }
  [ -f "$STATE/$2.meta" ] || exit 0
  FROM_LINE=$(awk 'NF { l = $0 } END { print l }' "$STATE/$2.status" 2>/dev/null) || exit 0
  FROM_KIND=$(jg_dod_meta_value "$STATE/$2.meta" kind)
  jg_dod_should_gate_ship_done "${FROM_KIND:-ship}" "$(jg_dod_meta_value "$STATE/$2.meta" mode)" "$FROM_LINE" || exit 0
  FROM_URL=$(jg_dod_pr_url_from_done_note "$(status_line_note "$FROM_LINE")") || exit 0
  jg_pr_url_parse "$FROM_URL" || exit 0
  [ "$(jg_dod_meta_value "$STATE/$2.meta" pr)" != "$JG_PR_URL" ] || exit 0
  set -- "$2" "$FROM_URL"
fi
ID=$1
RAW_URL=$2
if ! jg_pr_task_id_valid "$ID" || ! jg_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$JG_PR_URL
PROVIDER=$JG_PR_PROVIDER
HOST=$JG_PR_HOST
PROJECT_PATH=$JG_PR_PATH
NUMBER=$JG_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(jg_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A squad_lead is a persistent worker, not a delivery lane: it never owns a
# pull request of its own. A URL reported on its routed status channel belongs
# to a task inside the mate's own home, which records and watches it there;
# arming a merge watch here would queue the mate itself for teardown as landed
# work once that pull request merges.
KIND=$(jg_compat_kind "$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)")
if [ "$KIND" = squad_lead ]; then
  echo "error: $ID is a squad_lead, not a delivery lane - $URL was reported on its status channel but belongs to a task in the mate's own home, which arms its own merge watch" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
jg_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/jg-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a watch with no CLI on PATH to read it. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# change that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
# The Gerrit poll also needs jq, because Gerrit's status has to be read out of a
# structured record rather than off a rendered line: the tool's own table prints
# a change's subject before its status, and a subject is free text.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi
if [ "$PROVIDER" = gerrit ]; then
  if ! command -v gerrit-axi >/dev/null 2>&1; then
    echo "error: watching a Gerrit change requires gerrit-axi on PATH" >&2
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: watching a Gerrit change requires jq on PATH" >&2
    exit 1
  fi
fi

# Refuse to arm a Forgejo watch with no tea or jq on PATH, for the same reason
# as the GitLab and Gerrit cases above. tea also addresses a repo by slug only, resolving the
# host from a named "tea login" rather than from the URL the way gh and glab
# do, so a poll can only ever succeed when exactly one registered login
# matches this host; refuse now rather than watch something that can never
# resolve. This duplicates bin/jg-pr-poll.sh's own login match deliberately:
# that script is a static, standalone watcher body with no sourced
# dependency, so it re-derives the same match at every poll instead of
# trusting a name recorded here.
if [ "$PROVIDER" = forgejo ]; then
  if ! command -v tea >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "error: watching a Forgejo pull request requires tea and jq on PATH" >&2
    exit 1
  fi
  jg_pr_forgejo_login "$HOST" >/dev/null || {
    echo "error: watching a Forgejo pull request at $HOST requires exactly one 'tea login' registered for that host (see 'tea login list')" >&2
    exit 1
  }
fi

# The draft state is read before anything is recorded or armed. Only a positive
# draft reading refuses, because an unreadable one must not block arming.
if [ "$PROVIDER" = github ] && [ "${JG_PR_CHECK_MERGE:-}" != 1 ] && command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  DRAFT_JSON=$(gh pr view "$URL" --json isDraft 2>/dev/null || true)
  if [ "$(jg_pr_json_draft_state "$DRAFT_JSON")" = true ]; then
    echo "error: $URL is a draft pull request; a draft cannot be merged, so merge monitoring would wait for an event that cannot occur - mark it ready for review and arm again, or declare a wait instead of done if the draft is deliberate" >&2
    exit 1
  fi
fi

"$JG_ROOT/bin/jg-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor juggernaut does not require, and
# tea's single-PR view ignores field selection entirely, so neither a GitLab
# nor a Forgejo task records a pr_head here, and neither does a Gerrit task: a
# Gerrit revision names one patch set, every amend or rebase is a new patch set,
# and bin/jg-review-diff.sh has no Gerrit path to resolve a current head with,
# so a recorded revision would silently become the reviewed content. Both
# consumers already treat it as optional:
# bin/jg-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/jg-review-diff.sh fetches a pull request head from the remote when none is
# recorded and otherwise diffs the local branch, which is the current content.
# bin/jg-pr-merge.sh reads a GitLab or Forgejo head live at merge time for the
# same reason, and treats a recorded value that disagrees as stale rather than
# authoritative.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && jg_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PROJECT=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
# The optional receipts add-on chooses the receipt candidate from the worktree,
# pull request URL, mode, metadata path and verified forge head PR_HEAD (empty
# when unverified); its output must be empty (no candidate) or exactly PR_HEAD, or
# the check refuses.
# The gate is asked about the ready report this task's worker was told to give;
# on a Gerrit change both publishing modes report the same published line.
case "$PROVIDER:$MODE" in
  gerrit:*) DONE_LINE="done: PR $URL published for review" ;;
  *:no-mistakes|*:) DONE_LINE="done: PR $URL checks green" ;;
  *) DONE_LINE="done: PR $URL" ;;
esac
if [ -z "$PR_HEAD" ] || ! jg_dod_forge_head_is_named_head "$MODE"; then
  RECEIPT_CANDIDATE=
  if declare -F jg_receipts_pr_candidate >/dev/null; then
    if ! RECEIPT_CANDIDATE=$(jg_receipts_pr_candidate "$WT" "$URL" "$MODE" "$META" "$PR_HEAD"); then
      echo "error: receipts add-on hook jg_receipts_pr_candidate failed; no receipt candidate was chosen" >&2
      exit 1
    fi
    if [ -n "$RECEIPT_CANDIDATE" ] && [ "$RECEIPT_CANDIDATE" != "$PR_HEAD" ]; then
      echo "error: receipts add-on hook jg_receipts_pr_candidate returned a candidate other than the verified pull request head; no receipt candidate was chosen" >&2
      exit 1
    fi
  fi
  if ! GATE_REASON=$(jg_dod_accept_ship_done "${KIND:-ship}" "$MODE" "$WT" "$PROJECT" "$DONE_LINE" "$STATE" "$ID" "$META" "" "$RECEIPT_CANDIDATE"); then
    echo "error: $GATE_REASON" >&2
    exit 1
  fi
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
PR_POLL_PUBLISH_LOCK=
PR_POLL_PUBLISH_LOCK_HELD=0
pr_check_cleanup() {
  jg_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$PR_POLL_PUBLISH_LOCK_HELD" = 1 ]; then
    jg_lock_release "$PR_POLL_PUBLISH_LOCK" || true
    PR_POLL_PUBLISH_LOCK_HELD=0
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    jg_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
jg_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/jg-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(jg_meta_lock_path "$META") || exit 1
jg_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(jg_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(jg_pr_file_device "$META") || exit 1
STATE_DEVICE=$(jg_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.jg-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
jg_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
jg_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$JG_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$JG_PR_META_URL" = "$URL" ] \
  && [ "$JG_PR_META_HOST" = "$HOST" ] && [ "$JG_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$JG_PR_META_NUMBER" = "$NUMBER" ] || exit 1
jg_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
jg_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
jg_pr_metadata_identity_parse "$META" || exit 1
[ "$JG_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$JG_PR_META_URL" = "$URL" ] \
  && [ "$JG_PR_META_HOST" = "$HOST" ] && [ "$JG_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$JG_PR_META_NUMBER" = "$NUMBER" ] || exit 1
jg_lock_release "$META_LOCK"
META_LOCK_HELD=0

PR_POLL_PUBLISH_LOCK="$STATE/.pr-poll-publish-$ID.lock"
jg_lock_acquire_wait "$PR_POLL_PUBLISH_LOCK"
PR_POLL_PUBLISH_LOCK_HELD=1
if jg_pr_poll_publish_prepared; then
  jg_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
else
  jg_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
  echo "error: could not publish PR poll" >&2
  exit 1
fi
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
# The merge-time re-record is not a new review-ready PR, so it writes nothing.
[ ! -e "${JG_CONFIG_OVERRIDE:-$JG_HOME/config}/fleet-ledger" ] || [ "${JG_PR_CHECK_MERGE:-}" = 1 ] \
  || JG_HOME=$JG_HOME JG_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/jg-fleet-ledger.sh" pr_ready "$ID" "$URL" || true
# The contribution observer uses the same authenticated check mechanism and
# owns verdict freshness, required actors and external feedback separately from
# the exact merged-state poll. Registration is local and performs no forge read.
if command -v jq >/dev/null 2>&1; then
  "$SCRIPT_DIR/jg-contributions.sh" arm >/dev/null \
    || printf 'contributions: observation not armed; coverage is unconfirmed\n' >&2
else
  printf 'contributions: jq unavailable; coverage is unconfirmed\n' >&2
fi
# In a squad_lead home the registration itself is a captain-facing fact:
# publish the child's PR-ready line with the canonical URL just recorded, so it
# reaches the parent whether or not the mate model appends anything
# (bin/jg-parent-channel-lib.sh). A main home has no channel and this is a
# silent no-op there. The poll is armed either way; a channel that cannot be
# written is reported as actionable, and bin/jg-inactive-reconcile.sh still
# delivers the child's own ready line on the next supervision poll.
READY_LINE="done [key=child-pr-$ID]: child $ID PR ready: $URL"
PR_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PR_YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$PR_MODE" ] || READY_LINE="$READY_LINE mode=$(jg_parent_channel_clean_note "$PR_MODE")"
[ -z "$PR_YOLO" ] || READY_LINE="$READY_LINE yolo=$(jg_parent_channel_clean_note "$PR_YOLO")"
READY_RC=0
jg_parent_channel_report "$JG_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: PR %s is registered but its ready line did not reach the parent channel (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
# A newly ready pull request is waiting from this moment on, so it says what for
# on its own page (bin/jg-pr-lib.sh jg_pr_wait_status). The merge path replaces
# this line when its gate names a different wait and clears it before merging.
# The merge-time re-record is not a new wait start, so it writes nothing. A
# publish that fails is reported and never refuses the registration.
if [ "${JG_PR_CHECK_MERGE:-}" != 1 ] && [ "$PROVIDER" = github ]; then
  if [ "$PR_YOLO" = on ]; then
    jg_pr_wait_status "$URL" pending 'merge gate: automatic merge when green' \
      || printf 'warning: could not publish the waiting-for status on %s\n' "$URL" >&2
  else
    jg_pr_wait_status "$URL" pending 'merge gate: lead turn' \
      || printf 'warning: could not publish the waiting-for status on %s\n' "$URL" >&2
  fi
fi
# A new review-ready PR moves the ticket to review; the merge-time re-record does not.
[ "${JG_PR_CHECK_MERGE:-}" = 1 ] \
  || JG_HOME=$JG_HOME JG_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/jg-ticket.sh" "$ID" --stage review --pr "$URL" >/dev/null || true
# The ready card carries the task's proof media and receipt, or this says what is missing
# (bin/jg-proof-attach.sh). Homes with no board hook (config/post-merge) skip it.
if [ "${JG_PR_CHECK_MERGE:-}" != 1 ] && { [ -e "${JG_CONFIG_OVERRIDE:-$JG_HOME/config}/post-merge" ] || [ -n "${JG_PROOF_BOARD:-}" ]; }; then
  JG_HOME=$JG_HOME "$SCRIPT_DIR/jg-proof-attach.sh" attach ready "$ID" --pr "$URL" 2>&1 | sed 's/^/proof: /' >&2 || true
fi
printf 'armed: state/%s.check.sh\n' "$ID"
