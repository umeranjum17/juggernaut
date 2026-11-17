#!/usr/bin/env bash
# Usage: JG_HOME=<fleet home> wiring.sh [--dry-run]
#
# Installs the sync, its writer and its three registered watcher checks.
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
dest=${XDG_DATA_HOME:-$HOME/.local/share}/jg-tickets-sync
: "${JG_HOME:?set JG_HOME to the fleet home with data/squad_leads.md}"
if [ "${1:-}" = --dry-run ]; then echo "would install $dest and register tickets-sync, tickets-stale and tickets-cleanup"; exit; fi
[ "$#" = 0 ] || { echo 'usage: wiring.sh [--dry-run]' >&2; exit 2; }
mkdir -p "$dest/tickets-sync/icons" "$JG_HOME/state"
install -m 755 "$src/tickets-sync/"{sync,ticket}.py "$dest/tickets-sync/"
install -m 644 "$src/tickets-sync/"{identity,lane,hierarchy,task_rows,cleanup,legacy,reconcile,release,beads}.py "$dest/tickets-sync/"
cp -f "$src"/tickets-sync/icons/* "$dest/tickets-sync/icons/"
install -m 644 "$src/tickets-sync/drop.py" "$dest/tickets-sync/"
install -m 644 "$src/tickets-sync/tidy.py" "$dest/tickets-sync/"
for check in tickets-sync tickets-stale tickets-cleanup; do
  args=()
  case $check in tickets-stale) args=(--check) ;; tickets-cleanup) args=(--cleanup) ;; esac
  {
    printf '#!/usr/bin/env bash\nexport JG_HOME=%q\n' "$JG_HOME"
    # shellcheck disable=SC2016 # The generated check expands this default at runtime.
    printf 'export SIGN_OFF_TICKETS_ADAPTER=${SIGN_OFF_TICKETS_ADAPTER:-%q}\n' "$JG_HOME/bin/jg-ticket-adapter.py"
    # shellcheck disable=SC2016 # Keep the generated check's environment and config lookup literal.
    printf 'if [ -z "${BEADS_DIR:-}" ] && [ -f "$JG_HOME/config/beads-dir" ]; then export BEADS_DIR="$(cat "$JG_HOME/config/beads-dir")"; fi\n'
    printf 'exec python3 %q' "$dest/tickets-sync/sync.py"
    [ "${#args[@]}" = 0 ] || printf ' %q' "${args[@]}"
    printf ' 2>&1\n'
  } > "$JG_HOME/state/$check.check.sh"
done
chmod 700 "$JG_HOME/state/tickets-sync.check.sh" "$JG_HOME/state/tickets-stale.check.sh" "$JG_HOME/state/tickets-cleanup.check.sh"
env -u JG_STATE_OVERRIDE "$JG_HOME/bin/jg-check-register.sh" tickets-sync
env -u JG_STATE_OVERRIDE "$JG_HOME/bin/jg-check-register.sh" tickets-stale
env -u JG_STATE_OVERRIDE "$JG_HOME/bin/jg-check-register.sh" tickets-cleanup
