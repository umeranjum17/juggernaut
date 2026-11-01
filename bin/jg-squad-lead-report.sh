#!/usr/bin/env bash
# jg-squad-lead-report.sh - optional helper to append a correlated parent report.
#
# A squad_lead answering a marked from-juggernaut request must report on the
# parent status channel with the request's corr=<id> token. This helper makes
# that easy, but correctness must not depend on using it: a plain echo of a
# status line that includes the same corr token is equally valid
# (bin/jg-pending-reply-lib.sh).
#
# The write destination is mechanical: this helper never takes a status path.
# It resolves the parent channel through jg_parent_channel_destination
# (bin/jg-parent-channel-lib.sh): a local mate writes the parent home's
# state/<id>.status, and a remote mate writes this home's
# state/parent-replies.status. Call it from the squad_lead home with JG_HOME
# set to that home.
#
# Usage:
#   jg-squad-lead-report.sh <verb> <corr_id> <note...>
#   jg-squad-lead-report.sh --doc <verb> <corr_id> <doc-path> <note...>
#
# Examples:
#   jg-squad-lead-report.sh done abcdef0123456789 "audit clean"
#   jg-squad-lead-report.sh --doc done abcdef0123456789 data/x/report.md "see report"
#
# A report that names a wait is checked by core/status-wait-check: it receives
# <verb> <note> before the append and owns the wait rules. Its output is shown
# and a nonzero exit refuses the report with exit 2.
# bin/jg-live-claim.sh then owns the fixed-means-live rule: a note that reports a
# user-visible fix as done is written as `merged-not-released: ...` unless it
# carries the released ref and where it is observable, or states the truth itself,
# and the reporter sees that note on stderr.
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

CALLER_JG_HOME=${JG_HOME:-}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-pending-reply-lib.sh
. "$SCRIPT_DIR/jg-pending-reply-lib.sh"
# shellcheck source=bin/jg-parent-channel-lib.sh
. "$SCRIPT_DIR/jg-parent-channel-lib.sh"
# shellcheck source=bin/jg-question-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-question-lib.sh" \
  || { echo "error: the question rule needs $SCRIPT_DIR/jg-question-lib.sh beside this script" >&2; exit 1; }

jg_squad_lead_report_status_blocked_wait() {  # <verb> <text>
  local hook
  hook=$SCRIPT_DIR/../core/status-wait-check/status-wait-check
  [ -x "$hook" ] || return 0
  local out rc=0
  out=$("$hook" "$1" "$2" 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || exit 2
}

# Lavish is retired. The core guard refuses a Lavish address or publication
# command in a captain-facing note before anything reaches the parent channel,
# and names the sign-off board that replaced it (bin/jg-lavish-guard.sh).
jg_squad_lead_report_lavish_guard() {  # <text>
  local guard=$SCRIPT_DIR/jg-lavish-guard.sh
  [ -x "$guard" ] || return 0
  printf '%s\n' "$1" | "$guard" || exit 2
}

# The fixed-means-live rule (bin/jg-live-claim.sh owns it) downgrades a claim
# that a user-visible change is fixed when it carries no live evidence, so the
# parent reads the plain position instead of a fix nobody can use yet.
jg_squad_lead_report_live_claim() {  # <verb> <text> -> the note to write
  local check=$SCRIPT_DIR/jg-live-claim.sh text=$2 out rc=0
  if [ ! -x "$check" ]; then
    printf '%s\n' "$text"
    return 0
  fi
  out=$("$check" "$1" "$text") || rc=$?
  case "$rc" in
    0|3)
      if [ -n "$out" ]; then printf '%s\n' "$out"; else printf '%s\n' "$text"; fi
      ;;
    *) printf '%s\n' "$text" ;;
  esac
  return 0
}

usage() {
  cat <<'EOF' >&2
Usage:
  jg-squad-lead-report.sh <verb> <corr_id> <note...>
  jg-squad-lead-report.sh --doc <verb> <corr_id> <doc-path> <note...>
EOF
  exit 2
}

DOC_MODE=0
if [ "${1:-}" = "--doc" ]; then
  DOC_MODE=1
  shift
fi

[ $# -ge 2 ] || usage
VERB=$1
CORR=$2
shift 2
if [ "$DOC_MODE" = 1 ]; then
  [ $# -ge 1 ] && [ -n "$1" ] || usage
else
  [ $# -ge 1 ] && [ -n "$*" ] || usage
fi

case "$CORR" in
  corr=*) CORR=${CORR#corr=} ;;
esac
case "$CORR" in
  [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
  *)
    echo "error: corr_id must be 16 hex characters (got '$CORR')" >&2
    exit 1
    ;;
esac

HOME_DIR=$CALLER_JG_HOME
case "$HOME_DIR" in
  '')
    echo "error: JG_HOME is required so the helper can resolve the parent channel" >&2
    exit 1
    ;;
esac
STATE_DIR="${JG_STATE_OVERRIDE:-$HOME_DIR/state}"

DESTINATION=
DEST_RC=0
DESTINATION=$(jg_parent_channel_destination "$HOME_DIR" "$STATE_DIR") || DEST_RC=$?
if [ "$DEST_RC" -ne 0 ] || [ -z "$DESTINATION" ]; then
  echo "error: cannot resolve the parent channel from this home (not a seeded squad_lead?)" >&2
  exit 1
fi
mkdir -p "$(dirname "$DESTINATION")" 2>/dev/null || true
if [ ! -d "$(dirname "$DESTINATION")" ]; then
  echo "error: cannot create parent directory for status file '$DESTINATION'" >&2
  exit 1
fi

token=$(jg_pending_reply_corr_token "$CORR")
if [ "$DOC_MODE" = 1 ]; then
  DOC_PATH=$1
  shift
  NOTE=$*
  jg_question_flag_reply "$NOTE"
  jg_squad_lead_report_lavish_guard "$NOTE"
  jg_squad_lead_report_status_blocked_wait "$VERB" "$NOTE"
  NOTE=$(jg_squad_lead_report_live_claim "$VERB" "$NOTE")
  if [ -n "$NOTE" ]; then
    printf -v line '%s [%s]: %s (%s via-helper)' "$VERB" "$token" "$NOTE" "$DOC_PATH"
  else
    printf -v line '%s [%s]: %s (via-helper)' "$VERB" "$token" "$DOC_PATH"
  fi
else
  NOTE=$*
  jg_question_flag_reply "$NOTE"
  jg_squad_lead_report_lavish_guard "$NOTE"
  jg_squad_lead_report_status_blocked_wait "$VERB" "$NOTE"
  NOTE=$(jg_squad_lead_report_live_claim "$VERB" "$NOTE")
  printf -v line '%s [%s]: %s (via-helper)' "$VERB" "$token" "$NOTE"
fi
printf '%s\n' "$(status_stamp_line "$line")" >> "$DESTINATION"
