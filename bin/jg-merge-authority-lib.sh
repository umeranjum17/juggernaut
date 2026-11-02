#!/usr/bin/env bash
# Durable ownership of the authority under which a task's merge was accepted.
#
# The away-posture record (state/.afk-contract) is resolved only at the merge
# gate. After a forge accepts the merge, bin/jg-pr-merge.sh persists that answer
# as:
#   state/<task-id>.merge-authority
#   jg-merge-authority-v1
#   <provider>
#   <host>
#   <path>
#   <number>
#   <authority>                 away | attended
# While an away record exists every merge runs under away authority (the
# record's presence is the whole mechanical fact; which merge the captain's
# away words meant is the supervision session's reading); without one, or while
# the record is quiet mode's (bin/jg-afk-contract.sh mode: the captain is
# present), the merge is attended. The retired values yolo and away-grant are
# still accepted when an existing record is read, so a merge persisted before
# the words model landed is still consumed, but they are never written again.
# The identity comes from the merge run's immutable canonical URL parse;
# persistence revalidates the task's current pr= metadata under its metadata
# and lifecycle locks and refuses a mismatch. The file is atomically published,
# mode 0600, single-link, and on the state filesystem. A poll consumes it only
# when all identity fields match its own validated snapshot. Missing, malformed,
# or mismatched state means external; it is never resolved again from a later
# away-posture record.
#
# Resolution authorizes nothing by itself. bin/jg-pr-merge.sh owns the merge
# gate and persists only after a forge command succeeds, before releasing the
# task lifecycle lock. After observing a landed merge, bin/jg-watch.sh acquires
# that same lock, revalidates the poll, publishes its durable outcome, and
# retires only the exact authority record it read. Teardown uses the same lock,
# so it cannot interleave with that consumption transaction, and removes any
# remaining record.
#
# Sourced by those scripts and by tests. No side effects on source beyond its
# sourced libraries.

_JG_MERGE_AUTHORITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-pr-lib.sh
. "$_JG_MERGE_AUTHORITY_LIB_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-afk-contract.sh
. "$_JG_MERGE_AUTHORITY_LIB_DIR/jg-afk-contract.sh"

# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
JG_MERGE_AUTHORITY=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
JG_MERGE_AUTHORITY_REASON=
# shellcheck disable=SC2034 # Public results consumed by sourcing callers.
JG_MERGE_AUTHORITY_RECORD_IDENTITY=

jg_merge_authority_resolve() {  # <home> <state> <meta> <task-id>
  local home=${1-} state=${2-} meta=${3-} id=${4-}
  JG_MERGE_AUTHORITY=
  JG_MERGE_AUTHORITY_REASON='invalid'
  [ -n "$home" ] && [ -n "$state" ] && [ -n "$meta" ] && [ -n "$id" ] || return 1

  if ! jg_afk_contract_present "$state"; then
    JG_MERGE_AUTHORITY='attended'
    JG_MERGE_AUTHORITY_REASON='attended'
    return 0
  fi
  if ! JG_HOME="$home" JG_STATE_OVERRIDE="$state" \
    "$_JG_MERGE_AUTHORITY_LIB_DIR/jg-afk-contract.sh" validate >/dev/null 2>&1; then
    JG_MERGE_AUTHORITY_REASON='record-unreadable'
    return 1
  fi
  if ! jg_afk_contract_away_present "$state"; then
    JG_MERGE_AUTHORITY='attended'
    JG_MERGE_AUTHORITY_REASON='attended'
    return 0
  fi
  JG_MERGE_AUTHORITY='away'
  # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
  JG_MERGE_AUTHORITY_REASON='away'
  return 0
}

jg_merge_authority_record_matches() {  # <record> <device> <provider> <host> <path> <number>
  local record=$1 device=$2 expected_provider=$3 expected_host=$4 expected_path=$5 expected_number=$6
  local version provider host path number authority
  jg_pr_private_file_valid "$record" 600 "$device" || return 1
  exec 8< "$record" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  IFS= read -r provider <&8 || { exec 8<&-; return 1; }
  IFS= read -r host <&8 || { exec 8<&-; return 1; }
  IFS= read -r path <&8 || { exec 8<&-; return 1; }
  IFS= read -r number <&8 || { exec 8<&-; return 1; }
  IFS= read -r authority <&8 || { exec 8<&-; return 1; }
  if IFS= read -r _extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  case "$authority" in away|attended|yolo|away-grant) ;; *) return 1 ;; esac
  [ "$version" = jg-merge-authority-v1 ] \
    && [ "$provider" = "$expected_provider" ] \
    && [ "$host" = "$expected_host" ] \
    && [ "$path" = "$expected_path" ] \
    && [ "$number" = "$expected_number" ] || return 1
  JG_MERGE_AUTHORITY=$authority
}

jg_merge_authority_persist() {  # <state> <task-id> <meta> <provider> <host> <path> <number> <authority>
  local state=$1 id=$2 meta=$3 provider=$4 host=$5 path=$6 number=$7 authority=$8
  local record tmp='' state_device lock status=0
  jg_pr_task_id_valid "$id" || return 1
  case "$authority" in away|attended) ;; *) return 1 ;; esac
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(jg_pr_file_device "$state") || return 1
  jg_pr_metadata_identity_parse "$meta" || return 1
  [ "$JG_PR_META_PROVIDER" = "$provider" ] \
    && [ "$JG_PR_META_HOST" = "$host" ] \
    && [ "$JG_PR_META_PATH" = "$path" ] \
    && [ "$JG_PR_META_NUMBER" = "$number" ] || return 1
  record="$state/$id.merge-authority"
  lock="$record.lock"
  jg_lock_acquire_wait "$lock" || return 1
  jg_pr_regular_destination_on_device_or_absent "$record" "$state_device" || status=1
  if [ "$status" -eq 0 ]; then
    umask 077
    tmp=$(mktemp "$state/.jg-merge-authority.XXXXXX") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
      jg-merge-authority-v1 "$provider" "$host" "$path" "$number" "$authority" > "$tmp" \
      || status=1
  fi
  if [ "$status" -eq 0 ]; then
    chmod 0600 "$tmp" \
      && jg_merge_authority_record_matches "$tmp" "$state_device" \
        "$provider" "$host" "$path" "$number" \
      && jg_pr_regular_destination_on_device_or_absent "$record" "$state_device" \
      && mv -f -- "$tmp" "$record" \
      && jg_merge_authority_record_matches "$record" "$state_device" \
        "$provider" "$host" "$path" "$number" \
      || status=1
  fi
  [ "$status" -eq 0 ] || rm -f -- "$tmp"
  jg_lock_release "$lock" || status=1
  return "$status"
}

jg_merge_authority_read() {  # <state> <task-id> <provider> <host> <path> <number>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6
  local record state_device lock status=0
  JG_MERGE_AUTHORITY='external'
  JG_MERGE_AUTHORITY_RECORD_IDENTITY=
  jg_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(jg_pr_file_device "$state") || return 1
  record="$state/$id.merge-authority"
  lock="$record.lock"
  jg_lock_acquire_wait "$lock" || return 1
  if jg_merge_authority_record_matches "$record" "$state_device" \
      "$provider" "$host" "$path" "$number"; then
    # shellcheck disable=SC2034 # Public results consumed by sourcing callers.
    JG_MERGE_AUTHORITY_RECORD_IDENTITY=$(jg_pr_file_identity "$record") || status=1
  else
    JG_MERGE_AUTHORITY='external'
    status=1
  fi
  jg_lock_release "$lock" || status=1
  return "$status"
}

jg_merge_authority_remove_if_matches() {  # <state> <task-id> <provider> <host> <path> <number> <authority> <file-identity>
  local state=$1 id=$2 provider=$3 host=$4 path=$5 number=$6
  local authority=$7 expected_file_identity=$8 record state_device lock current_file_identity status=0
  jg_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(jg_pr_file_device "$state") || return 1
  record="$state/$id.merge-authority"
  lock="$record.lock"
  jg_lock_acquire_wait "$lock" || return 1
  if [ -e "$record" ] || [ -L "$record" ]; then
    if jg_merge_authority_record_matches "$record" "$state_device" \
        "$provider" "$host" "$path" "$number"; then
      current_file_identity=$(jg_pr_file_identity "$record") || status=1
      if [ "$status" -eq 0 ] \
        && [ "$JG_MERGE_AUTHORITY" = "$authority" ] \
        && [ "$current_file_identity" = "$expected_file_identity" ]; then
        rm -f -- "$record" || status=1
      fi
    elif ! jg_pr_private_file_valid "$record" 600 "$state_device"; then
      status=1
    fi
  fi
  jg_lock_release "$lock" || status=1
  return "$status"
}

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
