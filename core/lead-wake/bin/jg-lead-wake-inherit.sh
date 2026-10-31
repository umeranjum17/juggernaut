#!/usr/bin/env bash
# Sourced by jg-config-inherit-lib.sh right after it declares JG_INHERITABLE_CONFIG:
# a squad_lead home inherits the primary's config/lane-target. Appends to whatever
# list is declared, once, so Kun's own list stays untouched.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

case " $JG_INHERITABLE_CONFIG " in
  *" lane-target "*) ;;
  *) JG_INHERITABLE_CONFIG="$JG_INHERITABLE_CONFIG lane-target" ;;
esac
