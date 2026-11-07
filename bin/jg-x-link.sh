#!/usr/bin/env bash
# Link a spawned task to the X-mode mention that triggered it, so juggernaut can
# post up to THREE completion follow-ups when the task lands (within a 7-day window).
#
# Usage: jg-x-link.sh <task-id> <request_id> [--carry-count <n> --carry-ts <epoch> [--carry-platform <x|discord>] [--carry-max <n>]]
#
# Records link lines in state/<task-id>.meta (replacing any prior link,
# preserving every other meta line):
#   x_request=<request_id>     the relay-issued id the follow-up posts against
#   x_request_ts=<epoch>       link time, for the 7-day follow-up window
#   x_followups=<n>            follow-ups already posted against this binding
#   x_platform=<platform>      target platform, when known
#   x_reply_max_chars=<n>      target split budget, when known
#
# A fresh link always starts x_followups at 0 and uses the current time for
# x_request_ts. --carry-count <n> and --carry-ts <epoch> are a required pair for
# re-linking the SAME request onto a successor task (e.g. a stuck-operator
# recovery that respawns under a new task id): the caller reads the prior task's
# x_followups and x_request_ts before its meta goes away and passes both here,
# so the new task does not get a fresh follow-up budget, a refreshed local
# window, or a dropped reply-platform context against a binding the relay
# already knows about. Pass --carry-platform and --carry-max from the prior
# task's x_platform and x_reply_max_chars when the original inbox file is gone.
#
# Fresh-link context resolution fills platform and explicit budget independently
# through the durable per-request registry, inbox payload, then authoritative
# relay lookup by request_id. If either axis remains missing, the link is still
# recorded but a loud warning is printed and follow-ups fail closed.
#
# This is a separate step the relay-respond skill runs AFTER jg-spawn.sh, so it
# never changes jg-spawn's interface. The follow-up itself - detection, the
# window/cap check, the post, and clearing the link - is owned by
# jg-x-followup.sh on the task's captain-relevant wakes. The meta read/write
# lives in jg-x-lib.sh.
#
# THE LINK IS HOME-LOCAL BY CONSTRUCTION: it lives in this home's
# state/<task-id>.meta, so it can only bind work this home owns. Work routed to a
# squad_lead lives in that squad_lead's home and has no meta here, so a link is
# impossible and the public promise would be silently orphaned. When the task has
# no local meta, this refuses with the promised-final path (bin/jg-public-followup.sh
# register --work-home squad_lead:<id>) named, and names the squad_lead home the
# task was actually found in whenever a registered LOCAL route holds it.
#
# Both ids are relay/juggernaut slugs that compose a filename, so they are guarded
# against path traversal even though they come from trusted callers.
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
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
# shellcheck source=bin/jg-x-lib.sh
. "$SCRIPT_DIR/jg-x-lib.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-squad-lead-registry-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"

usage() {
  echo "usage: jg-x-link.sh <task-id> <request_id> [--carry-count <n> --carry-ts <epoch> [--carry-platform <x|discord>] [--carry-max <n>]]" >&2
}

ID=${1:-}
RID=${2:-}
if [ -z "$ID" ] || [ -z "$RID" ]; then
  usage
  exit 2
fi
shift 2

CARRY_COUNT=
CARRY_TS=
CARRY_PLATFORM=
CARRY_MAX=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --carry-count)
      shift
      CARRY_COUNT=${1:-}
      case "$CARRY_COUNT" in
        ''|*[!0-9]*) echo "jg-x-link: --carry-count needs a non-negative integer" >&2; exit 2 ;;
      esac
      ;;
    --carry-ts)
      shift
      CARRY_TS=${1:-}
      case "$CARRY_TS" in
        ''|*[!0-9]*) echo "jg-x-link: --carry-ts needs a non-negative epoch integer" >&2; exit 2 ;;
      esac
      ;;
    --carry-platform)
      shift
      CARRY_PLATFORM=${1:-}
      case "$CARRY_PLATFORM" in
        discord|x) ;;
        twitter) CARRY_PLATFORM=x ;;
        *) echo "jg-x-link: --carry-platform needs x or discord" >&2; exit 2 ;;
      esac
      ;;
    --carry-max)
      shift
      CARRY_MAX=${1:-}
      case "$CARRY_MAX" in
        ''|*[!0-9]*) echo "jg-x-link: --carry-max needs an integer of at least 50" >&2; exit 2 ;;
        *) [ "$CARRY_MAX" -ge 50 ] 2>/dev/null || { echo "jg-x-link: --carry-max needs an integer of at least 50" >&2; exit 2; } ;;
      esac
      ;;
    *) usage; exit 2 ;;
  esac
  shift
done
if [ -n "$CARRY_COUNT" ] && [ -z "$CARRY_TS" ]; then
  echo "jg-x-link: --carry-count requires --carry-ts to preserve the original follow-up window" >&2
  exit 2
fi
if [ -n "$CARRY_TS" ] && [ -z "$CARRY_COUNT" ]; then
  echo "jg-x-link: --carry-ts requires --carry-count to preserve the consumed follow-up count" >&2
  exit 2
fi
if { [ -n "$CARRY_PLATFORM" ] || [ -n "$CARRY_MAX" ]; } && { [ -z "$CARRY_COUNT" ] || [ -z "$CARRY_TS" ]; }; then
  echo "jg-x-link: --carry-platform and --carry-max require --carry-count and --carry-ts" >&2
  exit 2
fi

# task-id composes a path (state/<id>.meta); request_id composes a path elsewhere
# (the inbox/outbox record). Reject anything outside a safe slug for both.
jg_pr_task_id_valid "$ID" || { echo "jg-x-link: unsafe task id: $ID" >&2; exit 2; }
case "$RID" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "jg-x-link: unsafe request_id: $RID" >&2; exit 2 ;;
esac

# Scan this home's registered squad_leads for a task record with this id.
# ROUTE_MATCHES gets every LOCAL squad_lead whose seeded home actually holds
# state/<id>.meta; ROUTE_REGISTERED is 1 whenever any squad_lead is registered at
# all, which covers remote routes whose homes cannot be inspected from here. A
# home with no registry at all learns nothing new and keeps the plain error.
ROUTE_MATCHES=
ROUTE_REGISTERED=0
scan_squad_lead_routes() { # <task-id>
  local id=$1 reg line home marker
  reg=$(jg_compat_pick "$DATA/squad_leads.md")
  [ -f "$reg" ] && [ ! -L "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    squad_lead_registry_parse_line "$line" || continue
    ROUTE_REGISTERED=1
    [ "$SQUAD_LEAD_REGISTRY_REMOTE" -eq 0 ] || continue
    home=$SQUAD_LEAD_REGISTRY_HOME
    case "$home" in /*) ;; *) continue ;; esac
    home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || continue
    [ -f "$(jg_compat_marker "$home")" ] && [ ! -L "$(jg_compat_marker "$home")" ] || continue
    marker=$(sed -n '1p' "$(jg_compat_marker "$home")" 2>/dev/null)
    [ "$marker" = "$SQUAD_LEAD_REGISTRY_ID" ] || continue
    [ -f "$home/state/$id.meta" ] && [ ! -L "$home/state/$id.meta" ] || continue
    ROUTE_MATCHES="${ROUTE_MATCHES:+$ROUTE_MATCHES }$SQUAD_LEAD_REGISTRY_ID"
  done < "$reg"
}

META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  echo "jg-x-link: no such task: state/$ID.meta" >&2
  scan_squad_lead_routes "$ID"
  if [ -n "$ROUTE_MATCHES" ]; then
    printf 'jg-x-link: %s is a squad lead task (found in: %s), so this home cannot link it - a link only binds work whose record lives here.\n' \
      "$ID" "$ROUTE_MATCHES" >&2
  elif [ "$ROUTE_REGISTERED" -eq 1 ]; then
    printf 'jg-x-link: this home has registered squad leads and no record of %s, so the work may be routed to one - a link only binds work whose record lives here.\n' \
      "$ID" >&2
  fi
  if [ -n "$ROUTE_MATCHES" ] || [ "$ROUTE_REGISTERED" -eq 1 ]; then
    # One unambiguous match is worth naming exactly, so the pointer can be run
    # as printed instead of re-derived.
    ROUTE_HOME_ARG='squad_lead:<id>'
    case "$ROUTE_MATCHES" in
      ''|*' '*) ;;
      *) ROUTE_HOME_ARG="squad_lead:$ROUTE_MATCHES" ;;
    esac
    printf 'jg-x-link: bind the public promise through the promised-final path instead: bin/jg-backlog.sh public-followup add + bind-work, then bin/jg-public-followup.sh register <obligation-id> --relation <relation-id> --work-home %s --work-id %s --generation <n>, and put the bin/jg-public-followup.sh brief <obligation-id> command into the routed worker instructions.\n' \
      "$ROUTE_HOME_ARG" "$ID" >&2
  fi
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "jg-x-link: jq not found" >&2; exit 1; }
fmx_load_config
REQ_PLATFORM=
REQ_EXPLICIT_MAX=
REQ_REPLY_MAX=
if [ -n "$CARRY_PLATFORM" ]; then
  REQ_PLATFORM=$CARRY_PLATFORM
fi
if [ -n "$CARRY_MAX" ]; then
  REQ_REPLY_MAX=$CARRY_MAX
fi

if [ -z "$CARRY_TS" ]; then
  REPLY_CONTEXT=$(fmx_resolve_reply_context "$STATE" "$RID" 1) || {
    echo "jg-x-link: failed to resolve request reply context" >&2
    exit 1
  }
  REQ_PLATFORM=$(printf '%s' "$REPLY_CONTEXT" | jq -r '.platform // ""')
  REQ_EXPLICIT_MAX=$(printf '%s' "$REPLY_CONTEXT" | jq -r '.reply_max_chars // ""')
  REQ_REPLY_MAX=$REQ_EXPLICIT_MAX
fi

if [ -n "$CARRY_TS" ] && { [ -z "$REQ_PLATFORM" ] || [ -z "$REQ_REPLY_MAX" ]; }; then
  echo "jg-x-link: relink requires carried reply context; pass --carry-platform and --carry-max from the prior task" >&2
  exit 2
fi

if [ -z "$CARRY_TS" ] && { [ -z "$REQ_PLATFORM" ] || [ -z "$REQ_REPLY_MAX" ]; }; then
  echo "jg-x-link: WARNING: incomplete authoritative reply context for request $RID; every completion follow-up will be HELD until both platform and explicit budget can be resolved. Ensure the relay request-context lookup supplies both values." >&2
fi

FOLLOWUPS=0
if [ -n "$CARRY_TS" ]; then
  LINK_TS=$CARRY_TS
  FOLLOWUPS=$CARRY_COUNT
else
  # FMX_NOW_OVERRIDE keeps tests deterministic; production uses the wall clock.
  LINK_TS=${FMX_NOW_OVERRIDE:-$(date +%s)}
  case "$LINK_TS" in
    ''|*[!0-9]*) echo "jg-x-link: could not read the current time" >&2; exit 1 ;;
  esac
fi

if ! fmx_meta_link_set "$META" "$RID" "$LINK_TS" "$FOLLOWUPS" "$REQ_PLATFORM" "$REQ_REPLY_MAX"; then
  echo "jg-x-link: failed to record the link in state/$ID.meta" >&2
  exit 1
fi

printf 'linked %s to X request %s\n' "$ID" "$RID"
