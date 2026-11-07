#!/usr/bin/env bash
# One short-poll of the relay connector for a pending X-mode mention.
#
# Inert by default: a HARD no-op (exit 0, no output) unless X mode is configured
# via a non-empty FMX_PAIRING_TOKEN (from the home's .env or the environment).
# The watcher invokes this trusted repository script directly only after
# state/x-watch.check.sh matches the expected byte-static identity shim.
# Its contract is "output => wake juggernaut, silence => keep sleeping", so the
# no-op keeps the watcher behaving exactly as today until a user opts in.
#
# Behavior when X mode is on:
#   HTTP 204 / empty / missing text              -> print nothing, exit 0 (no wake)
#   auth/config errors                           -> print one rate-limited diagnostic
#   a newly offered mention with non-empty text -> stash the full object to
#       state/x-inbox/<request_id>.json, record the durable per-request reply
#       context to state/x-context/<request_id>.json (best-effort), atomically
#       claim state/x-context/<request_id>.offered.json, and print one compact
#       line "x-mention <request_id>" (which becomes the watcher wake payload)
#   an already offered request_id                -> print nothing, exit 0
#   a new set of unreconciled public-followup terminal results -> print one
#       "public-followup ..." line BEFORE the relay call, so a promised final
#       reply is surfaced through this same wake path
#   a terminal result bin/jg-public-followup.sh consume refused -> print its
#       "public-followup rejected <event-id> ..." line, with the specific
#       reason, at least once
#   a follow-up that failed with its link kept -> print one
#       "x-followup-held <task-id>" line and drop that marker, so a retryable
#       hold rings instead of waiting on a later milestone wake
#
# The public-followup line rides here rather than on a new poll of its own: this
# check only exists in a home that opted into the relay, and it is an O(1)
# directory presence test plus a signature compare, with no backlog call and no
# backlog scan. A home with no pending terminal results pays nothing for it.
# The full object is stashed verbatim, so every conversation-context field the
# relay includes is preserved for relay-respond to handle with continuity; the
# Relay section of docs/configuration.md owns that payload's wire contract. The
# durable context record lets a delayed follow-up recover the ORIGINAL
# platform/budget even after this inbox file is drained.
#
# Config (home .env, FMX_ENV_FILE, or env): FMX_PAIRING_TOKEN (required),
# FMX_RELAY_URL (default https://myjuggernaut.io). Auth: Authorization: Bearer
# <token>.
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
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
# shellcheck source=bin/jg-public-followup-lib.sh
# Also brings in bin/jg-x-lib.sh, which this script's relay client uses.
. "$SCRIPT_DIR/jg-public-followup-lib.sh"

fmx_load_config
# Hard no-op when X mode is off: this is what keeps the check shim inert.
[ -n "$FMX_TOKEN" ] || exit 0

# Unreconciled terminal results for a public commitment are actionable even when
# the relay has no new mention, and they outlive any session, so surface them
# first. The signature compare keeps this to one wake per new result set instead
# of one per cycle; bin/jg-public-followup.sh consume clears it.
if jg_pf_has_events "$STATE"; then
  PF_ROOT=$(jg_pf_root "$STATE")
  PF_SIG=$(jg_pf_events_signature "$STATE" 2>/dev/null) || PF_SIG=
  if [ -n "$PF_SIG" ] \
    && [ "$(cat "$PF_ROOT/$JG_PF_SURFACED_BASENAME" 2>/dev/null || true)" != "$PF_SIG" ]; then
    if printf '%s\n' "$PF_SIG" \
      | fmx_private_artifact_publish_stdin "$PF_ROOT" "$JG_PF_SURFACED_BASENAME" 600 2>/dev/null; then
      printf 'public-followup terminal results are waiting to be reconciled\n'
    fi
  fi
fi

# A terminal result consume refused is a promised reply that will never become
# ready on its own, so each refusal wakes this home with its specific reason.
# The queued line is removed only once it has been read AND written to this
# poll's stdout, which is the wake: a read that fails, a line that comes back
# empty, or a write that fails all leave the line queued for the next cycle. The
# read is its own step because a pipeline would report the status of its last
# stage, not of the read. Dropping a raised line is best-effort, so this wake is
# at-least-once: a wake directory that cannot be written raises the same refusal
# again, with the same event id and reason as the quarantine it came from.
PF_WAKES=$(jg_pf_rejection_wakes_dir "$STATE")
if jg_pf_dir_has_entry "$PF_WAKES"; then
  for PF_WAKE in "$PF_WAKES"/*; do
    [ -f "$PF_WAKE" ] && [ ! -L "$PF_WAKE" ] || continue
    PF_WAKE_LINE=$(sed -n '1p' "$PF_WAKE" 2>/dev/null) || continue
    PF_WAKE_LINE=$(printf '%s\n' "$PF_WAKE_LINE" | jg_pf_bound_bytes 800)
    [ -n "$PF_WAKE_LINE" ] || continue
    printf '%s\n' "$PF_WAKE_LINE" || continue
    rm -f -- "$PF_WAKE" 2>/dev/null || true
  done
fi

# A follow-up held with its link kept (bin/jg-x-followup.sh) rings here so
# Juggernaut retries it instead of waiting for a later milestone wake. Dropping
# the marker after the raise makes this at-least-once, exactly like a rejection
# wake above: a retry that fails again records a new hold.
X_HELD_DIR="$STATE/x-followup-held"
if [ -d "$X_HELD_DIR" ] && [ ! -L "$X_HELD_DIR" ]; then
  for X_HELD in "$X_HELD_DIR"/*; do
    [ -f "$X_HELD" ] && [ ! -L "$X_HELD" ] || continue
    printf 'x-followup-held %s\n' "${X_HELD##*/}" || continue
    rm -f -- "$X_HELD" 2>/dev/null || true
  done
fi

ERROR_FILE="$STATE/x-poll.error"
CLAIM_ERROR_FILE="$STATE/x-poll.claim-error"

emit_error_once() {
  local msg=$1
  if fmx_private_artifact_file_valid "$STATE" "x-poll.error" 600 \
    && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" \
    | fmx_private_artifact_publish_stdin "$STATE" "x-poll.error" 600 2>/dev/null || true
  printf 'x-mode-error %s\n' "$msg"
}

clear_error() {
  fmx_private_artifact_dir_device "$STATE" >/dev/null 2>&1 || return 0
  rm -f "$ERROR_FILE" 2>/dev/null || true
}

emit_claim_error_once() {
  local msg=$1
  if fmx_private_artifact_file_valid "$STATE" "x-poll.claim-error" 600 \
    && [ "$(cat "$CLAIM_ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" \
    | fmx_private_artifact_publish_stdin "$STATE" "x-poll.claim-error" 600 2>/dev/null || true
  printf 'x-mode-error %s\n' "$msg"
}

clear_claim_error() {
  fmx_private_artifact_dir_device "$STATE" >/dev/null 2>&1 || return 0
  rm -f "$CLAIM_ERROR_FILE" 2>/dev/null || true
}

command -v curl >/dev/null 2>&1 || { emit_error_once "missing curl"; exit 0; }
command -v jq   >/dev/null 2>&1 || { emit_error_once "missing jq"; exit 0; }

fmx_context_registry_prune "$STATE"

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/jg-x-poll.XXXXXX") || exit 0
AUTH_HEADER_FILE=
trap 'rm -f "$BODY_FILE" "$AUTH_HEADER_FILE"' EXIT
AUTH_HEADER_FILE=$(fmx_auth_header_file) || { emit_error_once "invalid token"; exit 0; }

# Short, bounded poll: a failure or timeout simply means "no wake this cycle";
# the next check cycle retries. -m 5 keeps this well inside the watcher's
# per-check timeout so the supervision loop is never starved.
code=$(curl -m 5 -s -o "$BODY_FILE" -w '%{http_code}' \
  -H "@$AUTH_HEADER_FILE" \
  -H 'Accept: application/json' \
  "$FMX_RELAY/connector/poll" 2>/dev/null) || exit 0

# 204 (nothing pending) is the common path; only 200 can carry a mention.
case "$code" in
  200) ;;
  204) clear_error; exit 0 ;;
  400|401|403|404) emit_error_once "relay returned HTTP $code"; exit 0 ;;
  *) exit 0 ;;
esac
[ -s "$BODY_FILE" ] || { clear_error; exit 0; }

REQ=$(jq -r '.request_id // empty' "$BODY_FILE" 2>/dev/null) || exit 0
[ -n "$REQ" ] || { clear_error; exit 0; }

# A pending mention only reaches the agent when it has non-empty text.
# Semantic worthiness is decided by relay-respond, so acknowledgments can still be
# stashed here and deliberately skipped there.
# Empty/absent/null text must not stash an inbox file or wake a public X flow for
# nothing - stay inert (exit 0).
TEXT=$(jq -r '(.text // "") | gsub("[[:space:]]+"; " ") | gsub("^ +| +$"; "")' "$BODY_FILE" 2>/dev/null) || exit 0
[ -n "$TEXT" ] || { clear_error; exit 0; }

# Defend the inbox filename: request_id is relay-issued (e.g. "req-7"), but never
# trust it into a path. Reject anything outside a safe slug.
case "$REQ" in
  ''|.*|*[!A-Za-z0-9._-]*) clear_error; exit 0 ;;
esac

# The offer marker outlives the inbox file, which relay-respond removes after a
# successful answer or dismiss. Checking it before the inbox stash keeps both a
# still-pending request and the relay's brief post-answer re-offer silent without
# recreating a drained inbox. The startup prune above bounds marker retention.
if fmx_private_artifact_file_valid "$STATE/x-context" "$REQ.offered.json" 600; then
  clear_error
  clear_claim_error
  exit 0
fi

INBOX="$STATE/x-inbox"
# Stash the full mention object atomically so a concurrent reader never sees a
# half-written file.
if ! (set -o pipefail; jq '.' "$BODY_FILE" 2>/dev/null \
  | fmx_private_artifact_publish_stdin "$INBOX" "$REQ.json" 600); then
  emit_error_once "cannot write inbox"
  exit 0
fi

# Record the durable per-request reply context from the authoritative relay
# payload, so a follow-up can recover the platform/budget even after this inbox
# file is drained and even when no task link survives (the single x_request per
# task collides across concurrent requests). Best-effort: the inbox stash above
# is the primary artifact and the relay lookup remains a fallback, so a registry
# write failure must never fail the poll or touch its one-line stdout wake
# payload. fmx_context_registry_set is a no-op when the platform is unknown.
POLL_CTX=$(fmx_extract_reply_context "$BODY_FILE" 2>/dev/null) || POLL_CTX=
if [ -n "$POLL_CTX" ]; then
  POLL_PLATFORM=$(printf '%s' "$POLL_CTX" | jq -r '.platform // ""' 2>/dev/null) || POLL_PLATFORM=
  POLL_MAX=$(printf '%s' "$POLL_CTX" | jq -r '.reply_max_chars // ""' 2>/dev/null) || POLL_MAX=
  fmx_context_registry_set "$STATE" "$REQ" "$POLL_PLATFORM" "$POLL_MAX" 2>/dev/null || true
fi

fmx_offer_registry_claim "$STATE" "$REQ"
offer_rc=$?
case "$offer_rc" in
  0) clear_error; clear_claim_error; printf 'x-mention %s\n' "$REQ" ;;
  1) clear_error; clear_claim_error; exit 0 ;;
  *) emit_claim_error_once "cannot record mention offer"; exit 0 ;;
esac
