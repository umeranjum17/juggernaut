#!/usr/bin/env bash
# A check reads each registered home's backlog from that home's own store and nothing else. A home with no Beads
# store (no config/beads-dir, or a blank one) has no backlog: the sync notes it once in its progress log, and the
# sync, the stale check and the clean-up never wake Main about it, never fail on it and never read it. Main and
# two leads have no store and a third lead has one. No bd, dolt or sign-off-axi is needed: stand-ins answer the
# reader and the board reads.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/tickets-sync-nostore.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
export HOME=$work/user XDG_DATA_HOME=$work/xdg
export JG_HOME=$work/main
mkdir -p "$HOME" "$JG_HOME"/{data,config,state,bin} "$work/fakebin" "$work/lead-none/config" "$work/lead-blank/config" "$work/lead-store/config"
printf '%s\n' "$work/board.json" > "$JG_HOME/config/fleet-board"
printf '\n' > "$work/lead-blank/config/beads-dir"
printf '%s\n' "$work/lead-store/.beads" > "$work/lead-store/config/beads-dir"
printf -- '- lead-none - no store (home: %s; scope: x; projects: x; added 2026-11-09)\n- lead-blank - blank store (home: %s; scope: x; projects: x; added 2026-11-09)\n- lead-store - has a store (home: %s; scope: x; projects: x; added 2026-11-09)\n' \
  "$work/lead-none" "$work/lead-blank" "$work/lead-store" > "$JG_HOME/data/squad_leads.md"
# The reader every home goes through. It logs the home it is asked about and answers the way the real one does: an
# empty list for a home with a store, a refusal on stderr with exit 2 for one without.
cat > "$JG_HOME/bin/jg-backlog.sh" <<SH
#!/usr/bin/env bash
echo "\$JG_HOME" >> '$work/reader.calls'
if [ -n "\$(tr -d '[:space:]' < "\$JG_HOME/config/beads-dir" 2>/dev/null)" ]; then echo 'tasks: 0 total'; exit 0; fi
echo "jg-backlog: the beads backlog needs its store: put an absolute BEADS_DIR in \$JG_HOME/config/beads-dir" >&2
exit 2
SH
chmod +x "$JG_HOME/bin/jg-backlog.sh"
cat > "$work/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
case "$1" in ticket) echo '{"tickets":[]}' ;; project) echo '{"projects":[]}' ;; list) echo '{"decisions":[]}' ;; *) exit 0 ;; esac
SH
chmod +x "$work/fakebin/sign-off-axi"
export PATH=$work/fakebin:$PATH
sync=$root/tickets-sync/sync.py
log=$JG_HOME/state/tickets-sync/progress.log
fail=0
# Main publishes its own upkeep ticket on a pass, and the board stand-in keeps nothing, so a pass may print its
# count line; what a no-store home must never cause is a failure, a word on stderr or a mention of a store.
for pass in 1 2; do
  for mode in --check --cleanup ''; do
    status=0
    python3 "$sync" $mode >"$work/out" 2>"$work/err" || status=$?
    if [ -s "$work/err" ] || [ "$status" != 0 ] || grep -qi 'store' "$work/out"; then
      echo "FAIL: pass $pass '${mode:-sync}' raised a wake for a home with no Beads store (exit $status): $(cat "$work/err" "$work/out")"; fail=1
    fi
    # The first read-only runs came before any sync: they note nothing.
    if [ "$pass" = 1 ] && [ -n "$mode" ] && grep -qs 'no Beads store' "$log"; then
      echo "FAIL: the read-only '$mode' wrote a no-store note"; fail=1
    fi
  done
done
# A home is read only through its own store: the one lead with a store, and no home without one.
unexpected=$(grep -vxF "$work/lead-store" "$work/reader.calls" 2>/dev/null || true)
[ -z "$unexpected" ] || { echo "FAIL: the backlog reader was run for a home with no store: $unexpected"; fail=1; }
grep -qxF "$work/lead-store" "$work/reader.calls" || { echo 'FAIL: the home with a store was never read'; fail=1; }
# Each home without a store is noted once, not once per pass.
for name in main lead-none lead-blank; do
  count=$(grep -c "^$name: no Beads store" "$log" || true)
  [ "$count" = 1 ] || { echo "FAIL: '$name' has no store and was noted $count times, not once"; fail=1; }
done
! grep -q '^lead-store: no Beads store' "$log" || { echo 'FAIL: the home with a store was noted as having none'; fail=1; }
# A home that later gets a store is read, and noted again if it loses it.
printf '%s\n' "$work/lead-none/.beads" > "$work/lead-none/config/beads-dir"
python3 "$sync" >"$work/out" 2>"$work/err" || { echo "FAIL: sync after lead-none gained a store: $(cat "$work/err")"; fail=1; }
grep -qxF "$work/lead-none" "$work/reader.calls" || { echo 'FAIL: lead-none gained a store and was not read'; fail=1; }
: > "$work/lead-none/config/beads-dir"
python3 "$sync" >"$work/out" 2>"$work/err" || { echo "FAIL: sync after lead-none lost its store: $(cat "$work/err")"; fail=1; }
[ "$(grep -c '^lead-none: no Beads store' "$log")" = 2 ] || { echo 'FAIL: lead-none lost its store and was not noted again'; fail=1; }
[ "$fail" = 0 ] || exit 1
echo 'PASS: each check reads only a home with a store, and a home with none is noted once and never wakes Main'
