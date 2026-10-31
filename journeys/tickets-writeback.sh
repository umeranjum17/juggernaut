#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# done-done journey: prove ticket write-back through the poll, lifecycle writer and
# fork shim; retain transcripts and the step record in $DONE_DONE_EVIDENCE_ROOT.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
cd "$REPO" || exit 1
failed=0

# 1. The port plus the writer and the check, through the feature's own suite and a
#    disposable fleet board: real tasks-axi, real sign-off-axi, no live board.
JG_TEST_FORK=$REPO bash core/tickets-sync/tests/sync.test.sh >"$OUT/tickets-sync-test.log" 2>&1 || failed=1
if grep -q '^PASS:' "$OUT/tickets-sync-test.log" && ! grep -q '^FAIL' "$OUT/tickets-sync-test.log"; then
  grep '^PASS:' "$OUT/tickets-sync-test.log" >"$OUT/tickets-sync-passed.log"
else
  failed=1
fi

# 2. The fork shim: silent without the feature or a board, and it hands an installed
#    writer this home's task and flags.
bash tests/jg-ticket.test.sh >"$OUT/jg-ticket-test.log" 2>&1 || failed=1

if [ "$failed" -ne 0 ]; then
  echo "tickets-writeback: a step failed; read tickets-sync-test.log and jg-ticket-test.log" >&2
fi

python3 - "$OUT/steps.json" "$(git rev-parse HEAD)" <<'PY'
import json, sys
steps = [
    "Run the feature sync test so a ticket publishes its stage and last event from the lane.",
    "Write a dispatched ticket's stage and state, then a delivered PR, through the lifecycle writer.",
    "Repeat the same write and read the board unchanged; confirm a ticket the poll never published is untouched.",
    "Make a ticket contradict its backlog item and read the check naming it, then settle the board and read silence.",
    "Run the fork shim test so a home without a board stays silent.",
]
with open(sys.argv[1], 'w') as out:
    json.dump({
        'target': {'version': sys.argv[2]},
        'start': 'A disposable board holds a ticket for a task seven days old and untouched; nothing on this branch has written a ticket yet.',
        'steps': steps,
        'result': 'Every ticket carries the stage, last event, state and delivered PR written when the work happens, '
                  'the check names a ticket that contradicts its work and falls silent when the board is true, '
                  'and the installed ticket writer and poll keep the sign-off board aligned with the source backlog.',
    }, out, indent=1)
    out.write('\n')
PY
exit "$failed"
