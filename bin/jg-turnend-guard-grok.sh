#!/usr/bin/env bash
# Grok Stop-hook adapter for the juggernaut PRIMARY turn-end guard.
#
# The exact running Stop payload selects one path. A typed native capability
# field delegates the shared guard's exit status and stderr directly back to
# that Grok process. Field absence preserves the pre-native one-resume fallback.
# Invalid or unreadable input starts neither path. Camel case has typed
# precedence over the legacy snake-case spelling when both are present.
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

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$PAYLOAD" | jq -n --stream -e '
  reduce inputs as $item (
    {};
    if (
      ($item | length) == 2
      and ($item[0] | length) > 0
      and (
        $item[0][0] == "sessionId"
        or $item[0][0] == "stopHookActive"
        or $item[0][0] == "stop_hook_active"
      )
    ) then
      .[$item[0][0]] = ((.[$item[0][0]] // 0) + 1)
    else
      .
    end
  )
  | all(.[]; . == 1)
' >/dev/null 2>&1 || exit 0
CAPABILITY=$(printf '%s' "$PAYLOAD" | jq -ser '
  if length != 1 then error("payload count")
  elif ((.[0] | type) != "object") then error("payload")
  else .[0] |
    if has("stopHookActive") then
      if ((.stopHookActive | type) == "boolean") then "native" else error("stopHookActive") end
    elif has("stop_hook_active") then
      if ((.stop_hook_active | type) == "boolean") then "native" else error("stop_hook_active") end
    else "legacy"
    end
  end
' 2>/dev/null) || exit 0

ROOT=${GROK_WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-}}
[ -n "$ROOT" ] || exit 0
ROOT=${ROOT%/}
[ -x "$ROOT/bin/jg-turnend-guard.sh" ] || exit 0

if [ "$CAPABILITY" = native ]; then
  printf '%s' "$PAYLOAD" | "$ROOT/bin/jg-turnend-guard.sh"
  RC=$?
  case "$RC" in
    0|2) exit "$RC" ;;
    *) exit 0 ;;
  esac
fi

# Only a genuine pre-native payload reaches this bounded compatibility path.
[ -n "${GROK_TURNEND_GUARD_ACTIVE:-}" ] && exit 0
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -er '
  .sessionId | select(type == "string" and length > 0)
' 2>/dev/null) || exit 0
command -v grok >/dev/null 2>&1 || exit 0

ERR=$(mktemp "${TMPDIR:-/tmp}/jg-turnend-grok.XXXXXX") || exit 0
trap 'rm -f "$ERR"' EXIT

printf '%s' "$PAYLOAD" | "$ROOT/bin/jg-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || exit 0

REASON=$(cat "$ERR" 2>/dev/null || true)
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
# shellcheck source=bin/jg-operational-input.sh
. "$ROOT/bin/jg-operational-input.sh"
jg_operational_input_encode turn-end-guard \
  "TURN WOULD END BLIND - supervision is off. Repair missing watcher supervision according to the session-start operating block before ending the turn.

$REASON" \
  PROMPT || exit 0

GROK_TURNEND_GUARD_ACTIVE=1 \
  GROK_HOME="${GROK_HOME:-$HOME/.grok}" \
  grok --resume "$SESSION_ID" \
    --cwd "$ROOT" \
    --output-format plain \
    -p "$PROMPT" >/dev/null 2>&1 || true
