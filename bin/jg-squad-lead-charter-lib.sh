#!/usr/bin/env bash
# Shared extraction of squad_lead registry summary and scope from a charter.
# Source only. JG_SQUAD_LEAD_CHARTER and JG_SQUAD_LEAD_SCOPE remain explicit
# caller overrides; otherwise the named sections in the filled brief are used.

normalize_registry_text() {
  awk '
    {
      gsub(/[;()]/, " ")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if ($0 != "") out = out (out == "" ? "" : " ") $0
    }
    END { print out }
  '
}

brief_section_text() {
  local brief=$1 heading=$2
  awk -v heading="# $heading" '
    $0 == heading { in_section=1; next }
    in_section && /^# / { exit }
    in_section { print }
  ' "$brief"
}

registry_summary_for_brief() {
  local brief=$1
  if [ -n "${JG_SQUAD_LEAD_CHARTER:-}" ]; then
    printf '%s\n' "$JG_SQUAD_LEAD_CHARTER" | normalize_registry_text
  else
    brief_section_text "$brief" "Charter" | normalize_registry_text
  fi
}

registry_scope_for_brief() {
  local brief=$1
  if [ -n "${JG_SQUAD_LEAD_SCOPE:-}" ]; then
    printf '%s\n' "$JG_SQUAD_LEAD_SCOPE" | normalize_registry_text
  else
    brief_section_text "$brief" "Routing scope" | normalize_registry_text
  fi
}

# The first move of a home, (none) -> provisioned, goes to the one move log (bin/jg-machine-guard.sh edge, which never
# refuses a writer): squad_lead_report_provisioned <id>. The shadow cannot place a home that has no registry line yet,
# so the writer names the first edge itself, before it writes the line. Later moves go through bin/jg-machine-shadow.sh.
squad_lead_report_provisioned() {
  local guard=${BASH_SOURCE[0]%/*}/jg-machine-guard.sh
  [ -x "$guard" ] || return 0
  "$guard" edge squad-lead '(none)' provisioned "$1" >/dev/null 2>&1 || true
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
