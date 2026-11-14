#!/usr/bin/env bash
# jg-branch-report.sh - the supervision branch's report surface off Pi: the
# command twin of the Pi branch extension's jg_branch_report tool, for a
# branch session run by the supervision host (docs/supervision-host.md).
#
# It records exactly one handled fleet event in the durable outcome store
# (bin/jg-branch-outcome.sh owns the store) and gives the host the receipt it
# requires before it counts a wake handled. It enforces the same scoping the
# Pi tool does (docs/pi-supervision-branch.md "Components and their owners"):
# while the host's current turn claims signal or stale rows, only the tasks
# those rows resolve to may be reported - `fleet` and any remembered task are
# refused before the store is touched - and a claim that names no task (a
# heartbeat review, or a claimed heartbeat or check row) is unscoped. The
# claimed task set comes from .pi/extensions/lib/jg-branch-dispatch.ts through
# the host's turn record; this script only compares against it.
#
# Usage:
#   jg-branch-report.sh --task <id|fleet> --verdict routine|captain \
#       --summary <text> [--silent true|false] [--wake <text>]
#
# The verdict criteria are owned by bin/jg-branch-prompt.sh ("Verdict: routine
# or captain"); --silent true is legal only for a routine outcome.
# bin/jg-live-claim.sh owns the fixed-means-live rule and is applied to the
# summary before it is stored: a summary that reports a user-visible fix as done
# is recorded as `Landed, not in use: ...` unless it carries the released ref
# and where it is observable, or states the truth itself.
# bin/jg-ticket-link-guard.sh owns the ticket rule: a captain verdict names the
# board ticket link its work belongs to, and is refused here when it names none.
# A `fleet` row summarizes many tickets and has no single ticket to name, so it
# is the one row this check leaves alone.
# --wake defaults to the wake reason the host recorded for the turn.
#
# Only the branch actor of a live host turn may report: JG_SUPERVISION_ACTOR
# must be "branch" and JG_BRANCH_REPORT_TURN must name the host's current turn
# record ($STATE/.supervision-host-turn), so a report typed after its turn
# ended, or from any other shell, is refused. Exit codes: 0 recorded, 1 the
# store refused or failed (nothing recorded), 2 usage, 3 refused (actor, turn,
# or scope).
#
# A non-silent row an away turn recorded after the captain returned (the turn
# record says posture=away, or predates the posture field, and no away record
# remains: none, or quiet mode's, whose captain is present; bin/jg-afk-contract.sh
# AWAY OR QUIET) may be missing from the return brief, so it is also queued
# for MAIN as a durable check wake keyed supervision-host-return:<seq>,
# presented by the drain until MAIN acknowledges it. bin/jg-afk-return.sh
# archives the record before it reads the store and this check follows the
# append, so every visible row is in the brief, queued, or both: the relay does
# not depend on the host surviving its turn or on its owner delivering the
# host's own handback. Silent outcomes remain in the store but are not queued
# or relayed as notes. An attended turn queues nothing: its captain rows reach
# MAIN through the host's branch-outcome exit and the drain's BRANCH OUTCOMES
# section (bin/jg-wake-drain.sh), and its routine rows stay in the store.
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
TURN_FILE="$STATE/.supervision-host-turn"
RECEIPTS="$STATE/.supervision-host-receipts"
# shellcheck source=bin/jg-afk-contract.sh
. "$SCRIPT_DIR/jg-afk-contract.sh"

usage() {
  sed -n '/^# Usage:/,/^# --wake/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

refuse() {
  printf 'report refused: %s\n' "$1" >&2
  exit 3
}

TASK='' VERDICT='' SUMMARY='' SILENT=false WAKE='' WAKE_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task) TASK=${2:-}; shift 2 || usage ;;
    --verdict) VERDICT=${2:-}; shift 2 || usage ;;
    --summary) SUMMARY=${2:-}; shift 2 || usage ;;
    --silent) SILENT=${2:-}; shift 2 || usage ;;
    --wake) WAKE=${2:-}; WAKE_SET=1; shift 2 || usage ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

TASK=$(printf '%s' "$TASK" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
SUMMARY=$(printf '%s' "$SUMMARY" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
case "$VERDICT" in routine|captain) ;; *) VERDICT= ;; esac
case "$SILENT" in true|false) ;; *) usage ;; esac
if [ -z "$TASK" ] || [ -z "$SUMMARY" ] || [ -z "$VERDICT" ]; then
  echo "invalid report: --task, --verdict (routine|captain), and --summary are required" >&2
  exit 2
fi
if [ "$SILENT" = true ] && [ "$VERDICT" != routine ]; then
  echo "invalid report: --silent true requires the routine verdict" >&2
  exit 2
fi

# The fixed-means-live rule (bin/jg-live-claim.sh owns it): a summary that
# reports a user-visible fix as done carries the released ref and where it is
# observable, or reaches the captain plainly as Landed, not in use.
if [ -x "$SCRIPT_DIR/jg-live-claim.sh" ]; then
  LIVE_RC=0
  LIVE_SUMMARY=$("$SCRIPT_DIR/jg-live-claim.sh" 'done' "$SUMMARY") || LIVE_RC=$?
  case "$LIVE_RC" in
    0|3)
      if [ -n "$LIVE_SUMMARY" ]; then SUMMARY=$LIVE_SUMMARY; fi
      ;;
  esac
fi

[ "${JG_SUPERVISION_ACTOR:-}" = branch ] \
  || refuse "only the supervision branch reports outcomes; MAIN acts on them instead"
TURN=${JG_BRANCH_REPORT_TURN:-}
case "$TURN" in
  ''|*[!A-Za-z0-9._-]*) refuse "no supervision wake is being handled by this shell" ;;
esac

turn_field() {  # <name>
  sed -n "s/^$1=//p" "$TURN_FILE" 2>/dev/null | head -n 1
}

[ -f "$TURN_FILE" ] && [ ! -L "$TURN_FILE" ] \
  || refuse "the wake this shell was handling is over; report only while handling a wake"
[ "$(turn_field turn)" = "$TURN" ] \
  || refuse "the wake this shell was handling is over; report only while handling a wake"

if [ "$(turn_field unscoped)" != 1 ]; then
  TASKS=$(turn_field tasks)
  case " $TASKS " in
    *" $TASK "*) ;;
    *)
      refuse "the wake being handled (row $(turn_field rows)) names ${TASKS:-no task}, not $TASK; report only that task, never fleet or a task from memory"
      ;;
  esac
fi

[ "$WAKE_SET" -eq 1 ] || WAKE=$(turn_field wake)

# The ticket rule (bin/jg-ticket-link-guard.sh owns it): a captain outcome the
# captain can act on names its board ticket, so the reply he reads opens it.
if [ "$VERDICT" = captain ] && [ "$TASK" != fleet ] && [ -x "$SCRIPT_DIR/jg-ticket-link-guard.sh" ]; then
  printf '%s\n' "$SUMMARY" | "$SCRIPT_DIR/jg-ticket-link-guard.sh" \
    || refuse "captain reply names no ticket; the line above names the fix"
fi

set -- append --task "$TASK" --verdict "$VERDICT" --summary "$SUMMARY" --silent "$SILENT"
[ -z "$WAKE" ] || set -- "$@" --wake "$WAKE"
if ! SEQ=$("$SCRIPT_DIR/jg-branch-outcome.sh" "$@"); then
  echo "outcome store append failed (nothing recorded)" >&2
  exit 1
fi
printf '%s\t%s\t%s\t%s\n' "$TURN" "$SEQ" "$VERDICT" "$TASK" >> "$RECEIPTS" || {
  echo "recorded seq $SEQ, but the host receipt could not be written; the host will hand this wake to MAIN" >&2
  exit 1
}
if [ "$SILENT" = true ]; then
  printf 'recorded seq %s [routine]; silent outcome remains in the outcome store\n' "$SEQ"
  exit 0
fi
if [ "$(turn_field posture)" = attended ]; then
  if [ "$VERDICT" = captain ] && ! jg_afk_contract_away_present "$STATE"; then
    printf 'recorded seq %s [captain]; MAIN processes it from its next drain\n' "$SEQ"
  else
    printf 'recorded seq %s [%s]; it waits in the outcome store for MAIN\n' "$SEQ" "$VERDICT"
  fi
  exit 0
fi
if ! jg_afk_contract_away_present "$STATE"; then
  # shellcheck source=bin/jg-wake-lib.sh
  . "$SCRIPT_DIR/jg-wake-lib.sh"
  if ! jg_wake_append check "supervision-host-return:$SEQ" \
    "check: supervision-host outcome $SEQ for $TASK [$VERDICT] was recorded after the captain returned, so the return brief may not show it; relay it to the captain: $SUMMARY"; then
    printf 'recorded seq %s [%s], but the captain has returned and its relay to MAIN could not be queued; the host hands this turn to MAIN\n' "$SEQ" "$VERDICT" >&2
    exit 0
  fi
  printf 'recorded seq %s [%s]; the captain has returned, so it is queued for MAIN to relay\n' "$SEQ" "$VERDICT"
  exit 0
fi
printf 'recorded seq %s [%s]; it waits in the outcome store for MAIN\n' "$SEQ" "$VERDICT"
