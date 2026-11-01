#!/usr/bin/env bash
# Sealed done-done proof for jg-model-pool (screen: none). Forced-limit fixture journey only.
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
export TMPDIR=${TMPDIR:-/var/tmp}
bash "$repo/account-pool/tests/model-pool.test.sh" | tee "$evidence/result.log"
cat >"$evidence/steps.json" <<'JSON'
{"target":{"version":"account-pool jg-model-pool JSON helper"},"start":"fixture Umer A/B pool readings and recording stand-in pool command; no login copy, no network, no real model CLI","steps":["pick A at 70% over B at 40% above the 15% eligibility floor","typed quota next on A yields B without repeating A","all Claude under floor falls over Sol then Goat then Cursor auto","credits-enabled registry account refused and logged","past overall deadline refuses","omitted pool_config uses JG_HOME default","explicit pool_config wins over default","omitted pool_config with no default file refuses"],"result":"helper rotates accounts and fallovers under one deadline; never usage credits; usable as lfm account_picker without pool_config"}
JSON
printf 'PASS: jg-model-pool forced-limit proof\n'
