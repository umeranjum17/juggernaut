#!/usr/bin/env bash
# done-done journey: the real bin/jg-machine-shadow.sh. A legal move a writer reports is one line in
# data/machine-moves.log (epoch, machine, id, from, event, to, writer); an illegal move is only in the shadow log.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-run}.log
cd "$REPO" || exit 1
{ bash tests/jg-machine-moves-log.test.sh && bash tests/jg-machine-shadow.test.sh; } > "$LOG" 2>&1 || { cat "$LOG"; exit 1; }
cat > "$OUT/steps.json" <<'J'
{"target":{"version":"bin/jg-machine-shadow.sh with bin/jg-machine-guard.sh edge"},"start":"a fixture machine whose record is in its start state","steps":["a writer reports a legal move through jg-machine-shadow.sh","a writer reports an illegal move"],"result":"the legal move is one line in data/machine-moves.log with epoch, machine, id, from, event, to and writer; the illegal move is only in the shadow log"}
J
