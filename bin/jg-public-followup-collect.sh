#!/usr/bin/env bash
# jg-public-followup-collect.sh - read and retire the typed terminal events a
# worker in THIS home staged for an owning home on another machine.
#
# WHY THIS EXISTS: a public promise is kept by the home that owns the relay
# consent and the thread binding. When the bound work lives in a REMOTE
# squad_lead home, that worker has no local path to the owning home's inbox, so
# `jg-public-followup-emit.sh --stage-in` leaves the typed event in this home's
# public-followup outbox instead. The owning home runs THIS command over the
# route's own transport (bin/jg-on.sh) to collect what is waiting. The transport
# only runs main -> squad_lead, so collection is a pull; nothing here ever
# reaches back out.
#
# WHAT IT DOES NOT DO: it never builds, edits, posts, or judges an event. The
# staged bytes are handed over verbatim, and the collecting home re-validates
# every field against its own registration and the backlog before accepting one.
#
# Usage:
#   jg-public-followup-collect.sh drain <obligation-id>
#       Print every staged event for <obligation-id>, one compact JSON document
#       per line, newest-first order not guaranteed. NON-DESTRUCTIVE: a dropped
#       connection must never be able to lose a terminal result, so the staged
#       copy is retained until the collecting home has it durably and retires it
#       with `drop`. Prints nothing and exits 0 when nothing is staged.
#
#   jg-public-followup-collect.sh drop <obligation-id> <event-id>
#       Retire one staged event once the collecting home holds it durably.
#       Idempotent: an already-absent event is a success, so a repeated or
#       replayed retirement is safe.
#
# JG_HOME selects the home to read, exactly as every other command the remote
# entrypoint runs. Events are matched on their own obligation_id field, never on
# a filename, so a hand-placed file cannot be collected under another loop's id.
#
# Output: drain prints event JSON on stdout, one per line. Exit 0 on success,
# including an empty outbox and an outbox holding a file too large or too broken
# to hand over - that one is named on stderr and left in place rather than
# blocking every other staged result. Exit 2 on a usage or validation error, and
# 1 when the outbox cannot be safely read or a retirement cannot be completed.
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
# shellcheck source=bin/jg-public-followup-lib.sh
. "$SCRIPT_DIR/jg-public-followup-lib.sh"

JG_HOME="${JG_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"

usage() {
  cat >&2 <<'EOF'
usage: jg-public-followup-collect.sh drain <obligation-id>
       jg-public-followup-collect.sh drop <obligation-id> <event-id>
EOF
}

# The header comment IS the help text, so the two can never drift apart.
help() { sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

die() { printf 'jg-public-followup-collect: %s\n' "$1" >&2; exit "${2:-2}"; }

# staged_file <event-id>: the one non-symlink regular file that may hold that
# event, or nothing.
staged_file() {
  local file
  file="$(jg_pf_outbox_dir "$STATE")/$1.json"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  printf '%s\n' "$file"
}

# One unusable staged file must never hold back a good one: it is reported on
# stderr and left exactly where it is, and the readable results still travel.
cmd_drain() {
  local obligation=${1:-} dir file event_id payload
  [ -n "$obligation" ] || { usage; exit 2; }
  jg_pf_slug_valid "$obligation" || die "unsafe obligation id: $obligation"
  command -v jq >/dev/null 2>&1 || die "jq is required to read a staged terminal event" 1

  dir=$(jg_pf_outbox_dir "$STATE")
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    return 0
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] \
    || die "staged-event outbox is not a safely readable directory: $dir" 1
  for file in "$dir"/*.json; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    event_id=$(basename "$file" .json)
    jg_pf_slug_valid "$event_id" || continue
    if [ "$(wc -c < "$file" 2>/dev/null || echo 0)" -gt "$JG_PF_EVENT_BYTES_MAX" ]; then
      printf 'jg-public-followup-collect: staged event %s exceeds %s bytes and was left in place\n' \
        "$event_id" "$JG_PF_EVENT_BYTES_MAX" >&2
      continue
    fi
    payload=$(jq -ce . "$file" 2>/dev/null) || {
      printf 'jg-public-followup-collect: staged event %s is not readable JSON and was left in place\n' \
        "$event_id" >&2
      continue
    }
    [ "$(printf '%s' "$payload" | jq -r '.obligation_id // empty' 2>/dev/null)" = "$obligation" ] \
      || continue
    printf '%s\n' "$payload"
  done
}

cmd_drop() {
  local obligation=${1:-} event_id=${2:-} file
  [ -n "$obligation" ] && [ -n "$event_id" ] || { usage; exit 2; }
  jg_pf_slug_valid "$obligation" || die "unsafe obligation id: $obligation"
  jg_pf_slug_valid "$event_id" || die "unsafe event id: $event_id"
  command -v jq >/dev/null 2>&1 || die "jq is required to retire a staged terminal event" 1

  file=$(staged_file "$event_id") || return 0
  # The obligation must match the event's own record, so one loop's collection
  # can never retire another loop's staged result.
  [ "$(jq -r '.obligation_id // empty' "$file" 2>/dev/null)" = "$obligation" ] \
    || die "staged event '$event_id' does not belong to obligation '$obligation'" 1
  rm -f -- "$file" 2>/dev/null || die "could not retire staged event '$event_id'" 1
}

case "${1:-}" in
  --help|-h|help) help; exit 0 ;;
  drain) shift; cmd_drain "$@" ;;
  drop)  shift; cmd_drop "$@" ;;
  '') usage; exit 2 ;;
  *) die "unknown subcommand '$1'" ;;
esac
