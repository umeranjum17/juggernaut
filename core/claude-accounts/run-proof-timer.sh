#!/usr/bin/env bash
# run-proof-timer.sh: the refresh timer proof for done-done. Installs the units into a throwaway XDG tree with a
# stub systemctl, lets systemd-analyze verify the generated units, shows the real dry run for the real home
# (writes nothing) and runs the fixture test. The host's timers are never touched.
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
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$evidence" "$work/bin" "$work/home"
printf '#!/bin/sh\nexit 0\n' >"$work/bin/systemctl"
chmod +x "$work/bin/systemctl"
{
  echo "== dry run for a home (nothing written)"
  "$repo/claude-accounts/install-timer.sh" --dry-run "${JG_HOME:-$work/home}"
  echo "== units written into a throwaway tree, verified by systemd-analyze"
  env PATH="$work/bin:$PATH" XDG_DATA_HOME="$work/data" XDG_CONFIG_HOME="$work/cfg" "$repo/claude-accounts/install-timer.sh" "$work/home"
  systemd-analyze --user verify "$work/cfg/systemd/user/jg-claude-accounts-quota.timer" "$work/cfg/systemd/user/jg-claude-accounts-quota.service"
  echo "verify: ok"
  cat "$work/cfg/systemd/user/jg-claude-accounts-quota.timer"
  echo "== fixture test"
  bash "$repo/claude-accounts/tests/claude-accounts-timer.test.sh"
} >"$evidence/timer.txt" 2>&1
cat "$evidence/timer.txt"
