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
mkdir -p "$evidence" "$work/home/state" "$work/home/core"
ln -sn "$repo/lane-scale" "$work/home/core/lane-scale"
export JG_HOME=$work/home

bash "$repo/claude-accounts/tests/claude-accounts.test.sh" >"$evidence/test.txt" 2>&1
"$repo/claude-accounts/bin/claude-accounts-quota.sh" >/dev/null
jq 'del(.accounts[].folder)' "$JG_HOME/state/claude-accounts.json" >"$evidence/reading.json"
# The reader's ledger (core/lane-scale/quota.sh): one line for each account reading, folder paths never written.
cp "$JG_HOME/state/quota-ledger.tsv" "$evidence/quota-ledger.tsv"
bash "$repo/../tests/jg-fleet-budget.test.sh" >"$evidence/fleet-budget.txt" 2>&1
echo "run-proof: fixture tests and a redacted dispatch reading are in $evidence"
jq -n --arg v "$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo unknown)" '{target: {version: $v}, start: "a quota reader with registered accounts and no ledger",
  steps: ["the quota reader reads each account", "the reader writes one ledger line for each account reading", "the fleet budget test drives the ledger, the blind alert, the host budget verdict and the heavy slots"],
  result: "state/quota-ledger.tsv holds a line for each reading, a reader with no good reading for 30 minutes raises quota-blind once, and 28 busy cores of 32 stop every lane"}' >"$evidence/steps.json"
