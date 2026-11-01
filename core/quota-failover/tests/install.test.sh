#!/usr/bin/env bash
# quota-failover install journey: wiring.sh --all on throwaway homes with the real fork's check registration
# (JG_TEST_FORK=<Juggernaut checkout>): reached homes are trusted and their shims run, parked, remote and broken
# homes are named, a rerun changes nothing, uninstall --all retires them all. No real home or HOME is touched.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -u
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
FORK=${JG_TEST_FORK:?set JG_TEST_FORK to a Juggernaut checkout}
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home XDG_DATA_HOME=$d/data
fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else no "$1: [$2] lacks [$3]"; fi; }

home() { # <dir>: a home with the fork's check registration scripts
  mkdir -p "$1/state" "$1/bin" "$1/config" "$1/data"
  for f in jg-check-register.sh jg-check-unregister.sh jg-check-lib.sh jg-pr-lib.sh; do cp "$FORK/bin/$f" "$1/bin/"; done
}
registered() { # <home>: 0 when the fork's reader trusts the watcher check's current bytes
  # shellcheck source=/dev/null # the fork's libraries, copied into the fixture home
  (. "$1/bin/jg-pr-lib.sh" && . "$1/bin/jg-check-lib.sh" && jg_custom_check_registered "$1/state" quota-failover-watch)
}
M=$d/main A=$d/alpha
home "$M"; home "$A"; mkdir -p "$d/broken/state"
cat >"$M/data/squad_leads.md" <<EOF
- alpha - Owns alpha. (home: $A; worktree: $d/wt)
- parkedone - Owns a parked app. (home: $d/parked; worktree: $d/wt)
- faraway - Owns a remote app. (host: box; root: /srv; home: /srv/fm; worktree: /srv/wt)
- broken - Owns a home with no juggernaut. (home: $d/broken; worktree: $d/wt)
EOF
printf '# parked\nparkedone\n' >"$M/config/parked-homes"
printf 'hand-made check\n' >"$A/state/quota-failover-watch.check.sh"

out=$("$SRC/quota-failover/wiring.sh" --dry-run --all "$M" 2>&1)
has "dry run names the alpha check" "$out" "would write: $A/state/quota-failover-watch.check.sh"
is "dry run writes nothing" "$(find "$M/state" "$XDG_DATA_HOME" -mindepth 1 2>/dev/null)" ""

out=$("$SRC/quota-failover/wiring.sh" --all "$M" 2>&1) && rc=0 || rc=$?
is "a home that cannot register fails the run" "$rc" 1
has "main is installed" "$out" "installed: main: $M/state/quota-failover-watch.check.sh"
has "alpha is installed" "$out" "installed: alpha: $A/state/quota-failover-watch.check.sh"
has "the parked home is skipped" "$out" "skipped: parkedone: parked"
has "the remote home is skipped" "$out" "skipped: faraway: a remote home"
has "the broken home is named" "$out" "skipped: broken: $d/broken has no bin/jg-check-register.sh"
for h in "$M" "$A"; do
  if registered "$h"; then ok "the fork trusts the check in ${h##*/}"; else no "the fork trusts the check in ${h##*/}"; fi
done
is "alpha's hand-made check is backed up" "$(cat "$A"/state/quota-failover-watch.check.sh.bak-*)" "hand-made check"
printf 'quota-failover: w1 stopped\n' >"$A/state/quota-failover.wake"
is "alpha's shim runs the installed check on alpha" "$("$A/state/quota-failover-watch.check.sh")" "quota-failover: w1 stopped"
for lib in parked-homes/bin/jg-parked-homes-lib.sh account-pool/bin/jg-account-pool-lib.sh account-pool/bin/jg-pool-claude-env.sh; do
  is "the installed watcher finds $lib at its own relative path" \
    "$(cmp "$SRC/$lib" "$XDG_DATA_HOME/jg-quota-failover/quota-failover/../$lib" && echo same)" same
done

"$SRC/quota-failover/wiring.sh" --all "$M" >/dev/null 2>&1
is "a rerun backs nothing up again" "$(find "$A/state" "$M/state" -name '*.bak-*' | wc -l)" 1
if registered "$A"; then ok "a rerun keeps the trust"; else no "a rerun keeps the trust"; fi

"$SRC/quota-failover/unwiring.sh" --all "$M" >/dev/null 2>&1
is "uninstall retires every check and trust" \
  "$(find "$M/state" "$A/state" -name 'quota-failover-watch.check*' ! -name '*.bak-*' | wc -l)" 0
is "uninstall removes the installed copy" "$([ -e "$XDG_DATA_HOME/jg-quota-failover" ] && echo present || echo gone)" gone

[ "$fails" -eq 0 ] || { echo "quota-failover install: $fails assertion(s) failed"; exit 1; }
echo "quota-failover install: all assertions held"
