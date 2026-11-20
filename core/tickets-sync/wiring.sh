#!/usr/bin/env bash
# Usage: JG_HOME=<fleet home> wiring.sh [--dry-run]
#
# Registers the sync's three watcher checks. Nothing is copied: each check runs the sync from the checkout this
# wiring ran from, so a home always runs its own version and no home can replace another's copy.
# Sync and stale observe Beads tickets without republishing their fields.
# A failed read names its cause; normal polls remain quiet.
# Cleanup runs `sync.py --cleanup` and prints one board line a day.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
src=$(cd "$(dirname "$0")/.." && pwd -P)
sync=$src/tickets-sync/sync.py
: "${JG_HOME:?set JG_HOME to the fleet home with data/squad_leads.md}"
if [ "${1:-}" = --dry-run ]; then echo "would register tickets-sync, tickets-stale and tickets-cleanup to run $sync"; exit; fi
[ "$#" = 0 ] || { echo 'usage: wiring.sh [--dry-run]' >&2; exit 2; }
mkdir -p "$JG_HOME/state"
for check in tickets-sync tickets-stale tickets-cleanup; do
  args=()
  case $check in tickets-stale) args=(--check) ;; tickets-cleanup) args=(--cleanup) ;; esac
  {
    printf '#!/usr/bin/env bash\nexport JG_HOME=%q\n' "$JG_HOME"
    # shellcheck disable=SC2016 # The generated check expands this default at runtime.
    printf 'export SIGN_OFF_TICKETS_ADAPTER=${SIGN_OFF_TICKETS_ADAPTER:-%q}\n' "$JG_HOME/bin/jg-ticket-adapter.py"
    printf 'exec python3 %q' "$sync"
    [ "${#args[@]}" = 0 ] || printf ' %q' "${args[@]}"
    printf ' 2>&1\n'
  } > "$JG_HOME/state/$check.check.sh"
done
chmod 700 "$JG_HOME/state/tickets-sync.check.sh" "$JG_HOME/state/tickets-stale.check.sh" "$JG_HOME/state/tickets-cleanup.check.sh"
env -u JG_STATE_OVERRIDE "$JG_HOME/bin/jg-check-register.sh" tickets-sync
env -u JG_STATE_OVERRIDE "$JG_HOME/bin/jg-check-register.sh" tickets-stale
env -u JG_STATE_OVERRIDE "$JG_HOME/bin/jg-check-register.sh" tickets-cleanup
