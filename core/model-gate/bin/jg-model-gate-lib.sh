#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# jg-model-gate-lib.sh - model-gate feature: jg_model_gate_hook, the entry point a harness launch calls before it starts
# anything. Sourced from $JG_ADDONS_DIR/model-gate/bin/; a home without the feature keeps only no-op hook lines.
# A provider the allow-list does not name is not limited, so this only ever refuses a model the list constrains.
#
# Hook point, in Juggernaut core rather than this repo - bin/jg-spawn.sh, beside the account-pool hook it already has:
#   source (after the account-pool source block, ~line 724):
#     _jg_mg=${JG_ADDONS_DIR:-${JG_HOME:-$SCRIPT_DIR/..}/projects/juggernaut-addons}/model-gate/bin/jg-model-gate-lib.sh
#     if [ -r "$_jg_mg" ]; then . "$_jg_mg" || { printf 'error: the model-gate feature at %s failed to load\n' "$_jg_mg" >&2; exit 1; }
#     else jg_model_gate_hook() { :; }; fi
#   call (right after `jg_account_hook spawn-validate || exit 1`, ~line 943, where $MODEL is parsed):
#     jg_model_gate_hook spawn-validate || exit 1

# jg_model_gate_check <provider> <model>: 0 allowed, or no gate reachable; 2 refused with the gate's one line on stderr.
jg_model_gate_check() {
  local gate=${JG_MODEL_GATE:-} rc=0
  [ -n "$gate" ] || gate=$(command -v jg-model-gate 2>/dev/null) || return 0
  "$gate" check "$1" "$2" >&2 || rc=$?
  case $rc in
  0) return 0 ;;
  1) return 2 ;;
  esac
  printf 'model-gate: the gate at %s could not check %s/%s (exit %s); launch not blocked\n' "$gate" "$1" "$2" "$rc" >&2
  return 0
}

jg_model_gate_hook() { # <event> [args]
  case ${1:-} in spawn-validate) ;; *) return 0 ;; esac
  local model=${MODEL:-}
  case $model in */*) ;; *) return 0 ;; esac # no provider segment: nothing this gate can read
  jg_model_gate_check "${model%%/*}" "$model"
}
