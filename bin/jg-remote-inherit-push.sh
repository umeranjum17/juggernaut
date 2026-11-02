#!/usr/bin/env bash
# Push the declared inherited-material allowlist to one remote squad_lead route.
# Usage: jg-remote-inherit-push.sh <squad-lead-id> <generation>
#
# The item set is derived from the ONE declared owner
# (JG_INHERITABLE_CONFIG in bin/jg-config-inherit-lib.sh), the same declaration
# the receiving bin/jg-remote-inherit.sh enforces, so the two implementations in
# one code revision cannot drift silently. Different local and remote revisions
# fail closed as documented by that owner. JG_CONFIG_INHERIT_LIVE=1 marks a live
# convergence push into an already-running home and skips session-scoped items,
# exactly as the local propagation path does.
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
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"

# shellcheck source=bin/jg-squad-lead-registry-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"
# shellcheck source=bin/jg-config-inherit-lib.sh
. "$SCRIPT_DIR/jg-config-inherit-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}
file_link_count() {
  if [ "$(uname)" = Darwin ]; then /usr/bin/stat -f %l "$1" 2>/dev/null; else stat -c %h "$1" 2>/dev/null; fi
}
[ "$#" -eq 2 ] || { echo "usage: jg-remote-inherit-push.sh <squad-lead-id> <generation>" >&2; exit 2; }
ID=$1
GENERATION=$2
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid squad_lead id: $ID" ;; esac
case "$GENERATION" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
[ "${#GENERATION}" -le 18 ] && [ "$GENERATION" -ge 1 ] || die "generation is outside the supported range"
REMOTE=$(squad_lead_registry_field "$(jg_compat_pick "$DATA/squad_leads.md")" "$ID" remote 2>/dev/null || true)
[ "$REMOTE" = 1 ] || die "squad_lead $ID is not a remote route"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/jg-remote-inherit-push.XXXXXX") || die "cannot create inheritance staging directory"
trap 'rm -rf -- "$TMP"' EXIT
EMPTY="$TMP/empty"
: > "$EMPTY"
EMPTY_HASH=$(sha256_file "$EMPTY") || die "cannot hash empty inheritance payload"

ITEMS=$(jg_config_inherit_items)
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ "${JG_CONFIG_INHERIT_LIVE:-0}" = 1 ]; then
    case "$rel" in
      config/*)
        if jg_config_inherit_item_session_scoped "${rel#config/}"; then
          printf 'unchanged: %s\n' "$rel"
          continue
        fi
        ;;
    esac
  fi
  case "$rel" in
    config/juggernaut-role)
      source="$TMP/juggernaut-role.resolved"
      jg_role_inherit_payload "$JG_HOME" "$CONFIG" "$source" || die "cannot resolve the primary role"
      ;;
    config/*) source="$CONFIG/${rel#config/}" ;;
    data/*) source="$DATA/${rel#data/}" ;;
  esac
  source_present=$(jg_config_source_present "$source") || exit 1
  if [ "$source_present" = 1 ]; then
    [ -f "$source" ] && [ ! -L "$source" ] || die "inherited source is unsafe: $source"
    [ "$(file_link_count "$source")" = 1 ] || die "inherited source is hardlinked: $source"
    if [ "$rel" = data/captain-shared.md ]; then
      if ! missing=$(shared_captain_header_valid "$source"); then
        reason="shared captain preferences have no valid primary-authoritative header"
        [ -z "$missing" ] || reason="$reason: missing \"$missing\""
        die "$reason"
      fi
    fi
    snapshot="$TMP/$(printf '%s' "$rel" | tr '/' '_')"
    cp -p -- "$source" "$snapshot" || die "cannot snapshot inherited source: $source"
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || die "inherited source snapshot is unsafe: $source"
    bytes=$(LC_ALL=C wc -c < "$snapshot" | tr -d ' ')
    hash=$(sha256_file "$snapshot") || die "cannot hash inherited source: $source"
    "$SCRIPT_DIR/jg-on.sh" --stdin "$ID" jg-remote-inherit.sh put "$rel" "$bytes" "$hash" "$GENERATION" < "$snapshot"
  else
    # This loop's heredoc is its control stream, not remote command input.
    "$SCRIPT_DIR/jg-on.sh" "$ID" jg-remote-inherit.sh absent "$rel" 0 "$EMPTY_HASH" "$GENERATION" < /dev/null
  fi
done <<EOF
$ITEMS
EOF
