#!/usr/bin/env bash
# jg-brief-inherit-lib.sh - shared worker-instruction inheritance for briefs. Source only.
#
# The fork's brief seam sources this when the feature checkout is present and calls:
#   jg_brief_inherit_shared <config-dir> <kind>   (bin/jg-brief.sh)
#   jg_brief_inherit_config                       (bin/jg-config-inherit-lib.sh)
# With the feature absent the seam lines are no-ops: only config/brief-include.md applies.

# owner-rules feature: run its lane check when owner-rules/wiring.sh wrote config/owner-rules.
# Marker without the lib is an error, so a moved features clone cannot silently drop the rules.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

jg_brief_inherit_owner_rules() {
  local lib=${BASH_SOURCE[0]%/*}/../../owner-rules/bin/jg-owner-rules-lib.sh
  [ -f "$1/owner-rules" ] || return 0
  [ -f "$lib" ] || { echo "error: $1/owner-rules is installed but $lib is missing" >&2; exit 1; }
  # shellcheck disable=SC1090 # the feature lib is found at run time
  . "$lib" && jg_owner_rules_check "${DATA:-}" "${ID:-}" "${MODE:-}" "$2"
}

# Prepend config/brief-include-shared.md to BRIEF_INCLUDE_BODY, which already holds the
# home-local include. Same rules as the local include: a present path that is not a readable
# regular file, or text carrying its own delivery-contract line, stops the scaffold.
jg_brief_inherit_shared() {
  local config=$1 kind=$2 file body
  jg_brief_inherit_owner_rules "$config" "$kind"
  [ "$kind" != squad_lead ] || return 0
  file=$config/brief-include-shared.md
  { [ -e "$file" ] || [ -L "$file" ]; } || return 0
  { [ -f "$file" ] && body=$(cat "$file" 2>/dev/null); } || {
    echo "error: $file must be a readable regular file" >&2
    exit 1
  }
  if printf '%s\n' "$body" | grep -q '^Delivery contract: mode='; then
    echo "error: $file must not carry a 'Delivery contract: mode=' line; the delivery mode is a per-task --mode decision" >&2
    exit 1
  fi
  [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] || return 0
  BRIEF_INCLUDE_BODY="${body}${BRIEF_INCLUDE_BODY:+$'\n'}${BRIEF_INCLUDE_BODY:-}"
}

# Declare the shared include inheritable, so config-push, bootstrap convergence and the
# remote push propagate its exact bytes (or its absence) to squad_lead homes.
jg_brief_inherit_config() {
  case " ${JG_INHERITABLE_CONFIG:-} " in
    *" brief-include-shared.md "*) ;;
    *) JG_INHERITABLE_CONFIG="${JG_INHERITABLE_CONFIG:+$JG_INHERITABLE_CONFIG }brief-include-shared.md" ;;
  esac
}
