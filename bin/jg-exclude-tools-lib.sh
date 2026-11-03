#!/usr/bin/env bash
# jg-exclude-tools-lib.sh - shared parsing and runtime-support checks for
# config/crew-exclude-tools, sourced by bin/jg-spawn.sh and bin/jg-control.sh.
#
# docs/configuration.md "Worker tool exclusions" owns the file format and
# operator contract; bin/jg-spawn.sh's header owns launch-flag mechanics.
# Name verification belongs inside the worker's loaded-tool registry, never
# in an out-of-band server connection from these launch-time checks.

# jg_exclude_tools_names <config-dir>: print the comma-joined names, empty when
# the file is absent or lists nothing. Non-zero with the reason on stderr when
# the file or an entry is invalid.
jg_exclude_tools_names() {
  local config=$1 file line names='' present
  file=$config/crew-exclude-tools
  present=$(perl -MErrno=ENOENT -e '
    if (lstat $ARGV[0]) { print 1 }
    elsif ($! == ENOENT) { print 0 }
    else { die "error: cannot inspect config/crew-exclude-tools: $!\n" }
  ' -- "$file") || return 1
  [ "$present" = 1 ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/crew-exclude-tools must be a readable regular file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
    '' | '#'*) continue ;;
    esac
    if [ -n "${line//[A-Za-z0-9_.-]/}" ]; then
      echo "error: config/crew-exclude-tools has a malformed entry '$line'; expected one tool name per line using only letters, digits, _ . and - (blank lines and # comment lines are allowed)" >&2
      return 1
    fi
    names="${names:+$names,}$line"
  done <"$file" || {
    echo "error: cannot read config/crew-exclude-tools" >&2
    return 1
  }
  printf '%s' "$names"
}

# jg_exclude_tools_check <harness> <raw-launch 0|1> <config-dir>: succeed when
# this launch can honor the home's list (empty list, or a runtime that hides
# tools); otherwise refuse naming the file. Prints the names on stdout.
jg_exclude_tools_check() {
  local harness=$1 raw=$2 config=$3 names
  names=$(jg_exclude_tools_names "$config") || return 1
  if [ -n "$names" ]; then
    if [ "$raw" = 1 ]; then
      echo "error: config/crew-exclude-tools lists tools to hide, but a raw launch command cannot hide tools; remove the entries or launch a runtime that supports them (pi, pi-signed)" >&2
      return 1
    fi
    case "$harness" in
    pi | pi-signed) ;;
    *)
      echo "error: config/crew-exclude-tools lists tools to hide, but the $harness runtime cannot hide tools, so this launch is refused rather than running with them available; empty the file or launch a runtime that supports exclusion (pi, pi-signed)" >&2
      return 1
      ;;
    esac
  fi
  printf '%s' "$names"
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
