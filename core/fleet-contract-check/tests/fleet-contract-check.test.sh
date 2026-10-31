#!/usr/bin/env bash
# E2E: fleet-contract-check passes on working callers and names the caller that breaks.
# Fixture fork home with stub callers and a throwaway HOME: nothing real is touched.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
unset JG_MAIN_HOME JG_HOME
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
fork=$d/fork
mkdir -p "$fork/bin" "$fork/config" "$d/guard"
printf '{"rules":[]}\n' > "$fork/config/crew-dispatch.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fork/bin/jg-dispatch-resolve.sh"
printf '#!/usr/bin/env bash\necho "checks-lint: PASS: fixture"\n' > "$d/legacy.sh"
printf '#!/usr/bin/env bash\n%s/guard/owner-guard merge-gate "$@" || exit $?\n' "$d" > "$fork/config/merge-gate"
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/guard/owner-guard"
chmod +x "$fork/bin/jg-dispatch-resolve.sh" "$d/legacy.sh" "$d/guard/owner-guard"
export JG_MAIN_HOME=$fork JG_DONE_DONE_BIN=$d/no-such-done-done JG_LEGACY_CHECKS_LINT=$d/legacy.sh
run() { bash "$ROOT/fleet-contract-check/fleet-contract-check" "$@" 2>&1; }

out=$(run) || { echo "FAIL healthy fleet: $out"; exit 1; }
for c in dispatch-resolve owner-guard checks-lint limit-prompt-move; do grep -qx "ok $c" <<<"$out" || { echo "FAIL no 'ok $c': $out"; exit 1; }; done

# A broken caller makes the check exit non-zero and name that caller, and only that one.
chmod -x "$d/guard/owner-guard"
rc=0; out=$(run) || rc=$?
[ "$rc" -eq 1 ] && grep -q '^FAIL owner-guard: ' <<<"$out" && grep -qx 'ok dispatch-resolve' <<<"$out" || { echo "FAIL broken owner-guard: rc=$rc $out"; exit 1; }
chmod +x "$d/guard/owner-guard"

printf '#!/usr/bin/env bash\necho "malformed rules file" >&2; exit 2\n' > "$fork/bin/jg-dispatch-resolve.sh"
rc=0; out=$(run dispatch-resolve) || rc=$?
[ "$rc" -eq 1 ] && grep -q '^FAIL dispatch-resolve: .*malformed rules file' <<<"$out" || { echo "FAIL broken dispatch-resolve: rc=$rc $out"; exit 1; }

# A candidate package that omits the library the installed mover loads fails the check, without a core library to fall back on.
cp -R "$ROOT" "$d/addons"
sed -i '/account-pool-lib.sh/d' "$d/addons/limit-prompt-move/wiring.sh"
rc=0; out=$(JG_ADDONS_DIR=$d/addons run limit-prompt-move) || rc=$?
[ "$rc" -eq 1 ] && grep -q '^FAIL limit-prompt-move: ' <<<"$out" || { echo "FAIL package missing the pool lib: rc=$rc $out"; exit 1; }

rc=0; out=$(run no-such-caller) || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL unknown caller: rc=$rc $out"; exit 1; }
echo "PASS fleet-contract-check"
