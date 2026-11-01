#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# done-done journey: prove the board follows the work itself - a backlog transition
# and the merge path each write their ticket with no sync run, a repeat reconcile is
# quick and quiet, the check names a contradiction, and the tickets checks are a
# batch class that does not wake on its own. Every transcript stays in
# $DONE_DONE_EVIDENCE_ROOT.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
cd "$REPO" || exit 1
failed=0

# 1. The poll, the check and the reconcile, through the add-on's own suite on a
#    disposable fleet board: real tasks-axi, real sign-off-axi, no live board. The
#    suite times a drifted reconcile and a settled one and prints both.
JG_TEST_FORK=$REPO bash addons/tickets-sync/tests/sync.test.sh >"$OUT/tickets-sync-test.log" 2>&1 || failed=1
if grep -q '^PASS:' "$OUT/tickets-sync-test.log" && ! grep -q '^FAIL' "$OUT/tickets-sync-test.log"; then
  grep -E '^(PASS|reconcile):' "$OUT/tickets-sync-test.log" >"$OUT/tickets-sync-passed.log"
else
  failed=1
fi

# 2. The write-back paths: a real backlog transition, the lifecycle transition
#    library, a captain hold and the merge path each move their own ticket, and a
#    home with no board stays a silent no-op.
bash tests/jg-ticket-writeback.test.sh >"$OUT/jg-ticket-writeback-test.log" 2>&1 || failed=1

# 3. The urgency class: the tickets checks are batch, their row is durable, and the
#    cycle gate leaves the cycle for a batch reason while an urgent one still wakes.
bash tests/jg-wake-route.test.sh >"$OUT/jg-wake-route-test.log" 2>&1 || failed=1

if [ "$failed" -ne 0 ]; then
  echo "tickets-writeback: a step failed; read tickets-sync-test.log, jg-ticket-writeback-test.log and jg-wake-route-test.log" >&2
fi

python3 - "$OUT/steps.json" "$(git rev-parse HEAD)" "$OUT" <<'PY'
import json, re, sys
out = sys.argv[3]

def passed(name):
    try:
        text = open(f'{out}/{name}').read()
    except OSError:
        return 0
    return len(re.findall(r'^ok - ', text, re.M))

def reconcile_times():
    try:
        text = open(f'{out}/tickets-sync-test.log').read()
    except OSError:
        return []
    return re.findall(r'^reconcile: (.+)$', text, re.M)

times = reconcile_times()
steps = [
    "Run the add-on sync test so a ticket publishes its stage and last event from the lane, and the stale check names a ticket its work contradicts.",
    f"Time a reconcile over a drifted disposable board and a settled one: {'; '.join(times) if times else 'no timing printed'}.",
    f"Move real backlog rows through the operator command and the lifecycle transition library: {passed('jg-ticket-writeback-test.log')} checks passed, covering start, done with a delivered PR, a hold with its reason, its release, and the merge path.",
    "Confirm a home with no fleet board writes nothing and still succeeds, so a board problem never fails a transition.",
    f"Classify the tickets checks batch, prove the durable row survives and that the cycle gate leaves the cycle for a batch reason while an urgent one still wakes: {passed('jg-wake-route-test.log')} checks passed.",
]
with open(sys.argv[1], 'w') as out_file:
    json.dump({
        'target': {'version': sys.argv[2]},
        'start': 'A disposable board holds tickets for a backlog whose rows nothing has moved yet, and the tickets checks were registered as ordinary checks whose stdout wakes Main.',
        'steps': steps,
        'result': 'A backlog transition and the merge path each write their own ticket with no sync run, '
                  'a reconcile settles a drifted board and stays quiet on a true one, '
                  'and the tickets checks are a batch class whose report arrives with a turn that happens anyway '
                  'instead of waking Main by itself.',
    }, out_file, indent=1)
    out_file.write('\n')
PY
exit "$failed"
