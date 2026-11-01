#!/usr/bin/env bash
# run-proof-pick.sh: the chooser proof for done-done. Uses the real pool pick jg-spawn calls
# (jg_account_pool_select from this repo's account-pool feature; JG_BIN names a Juggernaut checkout's bin/
# for jg-timeout-lib.sh) with a throwaway
# config/account-pool pointing at the chooser and the real accounts, then starts one tiny throwaway
# Haiku task on the picked profile folder with the launch prefix the pool builds, and reads quota again.
# Captures keep ids, names and percentages only: no folder path, no credential value.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
JG_BIN=${JG_BIN:?set JG_BIN to a Juggernaut checkout bin/}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$evidence" "$work/home/config" "$work/home/state" "$work/cwd"
export JG_HOME=$work/home SCRIPT_DIR=$JG_BIN
bash "$repo/claude-accounts/wiring.sh" "$JG_HOME" >/dev/null
summary() { # label: both accounts' windows from the file the reader wrote
  jq -r --arg l "$1" '.accounts[] | "\($l) \(.id) (\(.name)): 5h left \(.five_hour.left // "?")% window-started \(.five_hour.resets_at != null), 7d left \(.seven_day.left // "?")%"' "$JG_HOME/state/claude-accounts.json"
}
"$repo/claude-accounts/bin/claude-accounts-quota.sh" >/dev/null
{ summary before; } >"$evidence/pick.txt"

# shellcheck source=/dev/null
. "$repo/account-pool/bin/jg-account-pool-lib.sh"
tuple=$(jg_account_pool_select claude "$JG_HOME/config")
id=$(cut -f1 <<<"$tuple"); folder=$(cut -f3 <<<"$tuple"); shed=$(cut -f4 <<<"$tuple")
echo "pool pick for a new Claude worker: $id" >>"$evidence/pick.txt"
prefix='env'
for n in $shed; do prefix="$prefix -u $n"; done
# Signed in on the picked folder, asked the way the pin check asks (exit status only, nothing printed).
if env -i HOME="$HOME" PATH="$PATH" CLAUDE_CONFIG_DIR="$folder" claude auth status >/dev/null 2>&1; then echo "claude auth status on the picked profile: signed in" >>"$evidence/pick.txt"; fi
reply=$(cd "$work/cwd" && $prefix CLAUDE_CONFIG_DIR="$folder" claude -p --model claude-haiku-5-5 "Reply with the single word ok." </dev/null 2>&1 | head -c 200)
echo "throwaway worker (claude-haiku-5-5) on $id answered: $reply" >>"$evidence/pick.txt"
"$repo/claude-accounts/bin/claude-accounts-quota.sh" >/dev/null
summary after >>"$evidence/pick.txt"
cat "$evidence/pick.txt"
