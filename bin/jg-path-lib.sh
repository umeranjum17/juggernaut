#!/usr/bin/env bash
# jg-path-lib.sh - fork-free pathname helpers with no source-time side effects,
# so read-only callers can load them without any library's state setup.
#
# Each assigns <output-variable> exactly what `$(dirname -- <path>)` or
# `$(basename -- <path>)` would: POSIX component rules, and the command
# substitution's removal of trailing newlines.

jg_dirname_to() {  # <output-variable> <path>
  local jg_path=$2
  case "$jg_path" in
    '') jg_path=. ;;
    *[!/]*)
      jg_path=${jg_path%"${jg_path##*[!/]}"}
      case "$jg_path" in
        */*)
          jg_path=${jg_path%/*}
          jg_path=${jg_path%"${jg_path##*[!/]}"}
          [ -n "$jg_path" ] || jg_path=/
          ;;
        *) jg_path=. ;;
      esac
      ;;
    *) jg_path=/ ;;
  esac
  while [ "${jg_path%$'\n'}" != "$jg_path" ]; do jg_path=${jg_path%$'\n'}; done
  printf -v "$1" '%s' "$jg_path"
}

jg_basename_to() {  # <output-variable> <path>
  local jg_path=$2
  case "$jg_path" in
    '') ;;
    *[!/]*) jg_path=${jg_path%"${jg_path##*[!/]}"}; jg_path=${jg_path##*/} ;;
    *) jg_path=/ ;;
  esac
  while [ "${jg_path%$'\n'}" != "$jg_path" ]; do jg_path=${jg_path%$'\n'}; done
  printf -v "$1" '%s' "$jg_path"
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
