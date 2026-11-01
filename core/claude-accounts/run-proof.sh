#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# done-done proof: validate the fixture reader and capture a redacted real reading for dispatch.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$evidence" "$work/home/state"
export JG_HOME=$work/home

bash "$repo/claude-accounts/tests/claude-accounts.test.sh" >"$evidence/test.txt" 2>&1
"$repo/claude-accounts/bin/claude-accounts-quota.sh" >/dev/null
jq 'del(.accounts[].folder)' "$JG_HOME/state/claude-accounts.json" >"$evidence/reading.json"
echo "run-proof: fixture tests and a redacted dispatch reading are in $evidence"
