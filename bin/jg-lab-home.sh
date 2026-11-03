#!/usr/bin/env bash
# jg-lab-home.sh - mint a disposable juggernaut "lab" home.
#
# A lab home is a throwaway JG_HOME that a no-mistakes GATE agent may drive
# through the fleet lifecycle entrypoints: bin/jg-gate-refuse-lib.sh refuses
# those calls inside a gate agent unless JG_HOME carries the marker file this
# helper writes (the lib owns the marker format and authorization decision;
# this script is the supported writer).
#
# Usage:
#   jg-lab-home.sh create <dir>       make a marked lab home and print it
#   jg-lab-home.sh tmux-dir <dir>     create or print its private tmux socket dir
#   jg-lab-home.sh teardown <dir>     remove its private tmux socket dir
#
# A lab home is the stock layout only - state/, data/, config/, projects/ - and
# callers remove it with ordinary rm -rf when done. Drive it with plain
# JG_HOME=<dir>; any JG_*_OVERRIDE relocation defeats the allowance.
# tmux-dir is the single owner of the short private socket directory: callers
# use TMUX_TMPDIR=<printed-dir> and call teardown from their cleanup trap after
# killing only the server addressed through that directory.
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
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-gate-refuse-lib.sh
. "$SCRIPT_DIR/jg-gate-refuse-lib.sh"

jg_lab_home_error() {
  echo "jg-lab-home: $*" >&2
}

jg_lab_home_tmux_record() { printf '%s/state/.jg-lab-tmux-dir' "$1"; }
jg_lab_home_mode() {
  case "$(uname -s)" in Darwin) stat -f '%Lp' "$1" ;; *) stat -c '%a' "$1" ;; esac
}
jg_lab_home_owner() {
  case "$(uname -s)" in Darwin) stat -f '%u' "$1" ;; *) stat -c '%u' "$1" ;; esac
}

case "${1:-}" in
  create)
    dir=${2:-}
    [ -n "$dir" ] || { jg_lab_home_error "create requires a directory path"; exit 2; }
    if [ -e "$dir" ] && [ ! -d "$dir" ]; then
      jg_lab_home_error "refusing '$dir': exists and is not a directory"
      exit 1
    fi
    mkdir -p "$dir" || exit 1
    jg_gate_lab_mark "$dir" || {
      jg_lab_home_error "refusing '$dir': a lab marker is only ever stamped on a fresh empty dir"
      exit 1
    }
    mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/projects" || exit 1
    printf '%s\n' "$dir"
    ;;
  tmux-dir)
    dir=${2:-}
    [ -n "$dir" ] || { jg_lab_home_error "tmux-dir requires a marked lab home"; exit 2; }
    [ -f "$dir/.jg-lab-home" ] && [ -d "$dir/state" ] \
      || { jg_lab_home_error "refusing '$dir': not a marked lab home"; exit 1; }
    record=$(jg_lab_home_tmux_record "$dir")
    if [ -f "$record" ]; then
      socket_dir=$(cat "$record")
      case "$socket_dir" in /tmp/fml.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;; *) jg_lab_home_error "invalid recorded tmux directory"; exit 1 ;; esac
      [ -d "$socket_dir" ] && [ ! -L "$socket_dir" ] \
        || { jg_lab_home_error "recorded tmux directory is missing or unsafe"; exit 1; }
      [ "$(jg_lab_home_mode "$socket_dir")" = 700 ] && [ "$(jg_lab_home_owner "$socket_dir")" = "$(id -u)" ] \
        || { jg_lab_home_error "recorded tmux directory is not private and user-owned"; exit 1; }
    else
      socket_dir=$(mktemp -d /tmp/fml.XXXXXX) || exit 1
      chmod 700 "$socket_dir" || { rmdir "$socket_dir" 2>/dev/null || true; exit 1; }
      [ "$(jg_lab_home_mode "$socket_dir")" = 700 ] && [ "$(jg_lab_home_owner "$socket_dir")" = "$(id -u)" ] \
        || { rmdir "$socket_dir" 2>/dev/null || true; jg_lab_home_error "cannot secure tmux directory"; exit 1; }
      (umask 077; printf '%s\n' "$socket_dir" > "$record") || { rmdir "$socket_dir" 2>/dev/null || true; exit 1; }
      chmod 600 "$record" || { rm -f "$record"; rmdir "$socket_dir" 2>/dev/null || true; exit 1; }
    fi
    printf '%s\n' "$socket_dir"
    ;;
  teardown)
    dir=${2:-}
    [ -n "$dir" ] || { jg_lab_home_error "teardown requires a marked lab home"; exit 2; }
    [ -f "$dir/.jg-lab-home" ] && [ -d "$dir/state" ] \
      || { jg_lab_home_error "refusing '$dir': not a marked lab home"; exit 1; }
    record=$(jg_lab_home_tmux_record "$dir")
    [ -f "$record" ] || exit 0
    socket_dir=$(cat "$record")
    case "$socket_dir" in /tmp/fml.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;; *) jg_lab_home_error "invalid recorded tmux directory"; exit 1 ;; esac
    [ -d "$socket_dir" ] && [ ! -L "$socket_dir" ] \
      || { jg_lab_home_error "recorded tmux directory is missing or unsafe"; exit 1; }
    [ "$(jg_lab_home_mode "$socket_dir")" = 700 ] && [ "$(jg_lab_home_owner "$socket_dir")" = "$(id -u)" ] \
      || { jg_lab_home_error "refusing to remove a non-private or non-user-owned tmux directory"; exit 1; }
    # -L names its own socket (not "default"); inspect every socket this
    # private TMUX_TMPDIR could have hosted before removing the directory.
    for socket in "$socket_dir/tmux-$(id -u)"/*; do
      [ -e "$socket" ] || [ -L "$socket" ] || continue
      if probe=$(tmux -S "$socket" list-sessions 2>&1 >/dev/null) \
        || [ "${probe#*no server running}" = "$probe" ]; then
        jg_lab_home_error "refusing teardown: cannot confirm the lab tmux server has stopped"
        exit 1
      fi
    done
    rm -rf "$socket_dir" && rm -f "$record"
    ;;
  *)
    jg_lab_home_error "usage: jg-lab-home.sh create <dir> | tmux-dir <dir> | teardown <dir>"
    exit 2
    ;;
esac
