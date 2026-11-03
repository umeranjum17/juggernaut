#!/usr/bin/env bash

JG_CUSTOM_CHECK_HASH=
JG_CUSTOM_CHECK_SNAPSHOT=

jg_custom_check_sha256() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

jg_custom_check_trust_read() {
  local state=$1 id=$2 trust state_device version hash
  JG_CUSTOM_CHECK_HASH=
  jg_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(jg_pr_file_device "$state") || return 1
  trust="$state/$id.check-trust"
  jg_pr_private_file_valid "$trust" 600 "$state_device" || return 1
  exec 9< "$trust" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r hash <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  # Compatibility (slice S5): a check registered before the rename still carries
  # the old schema line, so its binding keeps verifying instead of silently
  # disarming the check. Re-registering writes the current spelling.
  jg_compat_record_ok "$version" jg-custom-check-v1 "$(jg_compat_legacy_of jg-custom-check-v1)" || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  JG_CUSTOM_CHECK_HASH=$hash
}

jg_custom_check_registered() {
  local state=$1 id=$2 check hash state_device
  check="$state/$id.check.sh"
  jg_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(jg_pr_file_device "$state") || return 1
  jg_pr_private_file_valid "$check" 700 "$state_device" || return 1
  hash=$(jg_custom_check_sha256 "$check") || return 1
  [ "$hash" = "$JG_CUSTOM_CHECK_HASH" ]
}

jg_custom_check_snapshot_prepare() {
  local state=$1 id=$2 check hash state_device
  jg_custom_check_snapshot_cleanup
  check="$state/$id.check.sh"
  jg_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(jg_pr_file_device "$state") || return 1
  jg_pr_private_file_valid "$check" 700 "$state_device" || return 1
  JG_CUSTOM_CHECK_SNAPSHOT=$(mktemp "$state/.jg-custom-check.XXXXXX") || return 1
  cp "$check" "$JG_CUSTOM_CHECK_SNAPSHOT" || { jg_custom_check_snapshot_cleanup; return 1; }
  chmod 0600 "$JG_CUSTOM_CHECK_SNAPSHOT" || { jg_custom_check_snapshot_cleanup; return 1; }
  [ -f "$JG_CUSTOM_CHECK_SNAPSHOT" ] && [ ! -L "$JG_CUSTOM_CHECK_SNAPSHOT" ] \
    || { jg_custom_check_snapshot_cleanup; return 1; }
  [ "$(jg_pr_file_mode "$JG_CUSTOM_CHECK_SNAPSHOT")" = 600 ] \
    || { jg_custom_check_snapshot_cleanup; return 1; }
  [ "$(jg_pr_file_device "$JG_CUSTOM_CHECK_SNAPSHOT")" = "$state_device" ] \
    || { jg_custom_check_snapshot_cleanup; return 1; }
  [ "$(jg_pr_file_link_count "$JG_CUSTOM_CHECK_SNAPSHOT")" = 1 ] \
    || { jg_custom_check_snapshot_cleanup; return 1; }
  hash=$(jg_custom_check_sha256 "$JG_CUSTOM_CHECK_SNAPSHOT") \
    || { jg_custom_check_snapshot_cleanup; return 1; }
  [ "$hash" = "$JG_CUSTOM_CHECK_HASH" ] || { jg_custom_check_snapshot_cleanup; return 1; }
}

jg_custom_check_snapshot_cleanup() {
  [ -z "$JG_CUSTOM_CHECK_SNAPSHOT" ] || rm -f -- "$JG_CUSTOM_CHECK_SNAPSHOT"
  JG_CUSTOM_CHECK_SNAPSHOT=
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
