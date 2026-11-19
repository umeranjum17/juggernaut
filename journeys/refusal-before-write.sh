#!/usr/bin/env bash
# done-done journey: an illegal ticket move is refused before the authoritative write, through the real writers (bin/jg-beads-write.py add,
# the close transition of bin/jg-backlog-transition-lib.sh, the trace and moment writers) on a real Beads store in an isolated home with the
# ticket machine enforced. The isolated home's own config/machine-enforce is the only switch; no live home is touched.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-run}.log
cd "$REPO" || exit 1
JG_BEADS_TEST_BD=${JG_BEADS_TEST_BD:-$(command -v bd)} JG_BEADS_TEST_DOLT=${JG_BEADS_TEST_DOLT:-$(command -v dolt)}
export JG_BEADS_TEST_BD JG_BEADS_TEST_DOLT
{ bash tests/jg-move-writers.test.sh && bash tests/jg-move.test.sh && bash tests/jg-machine-ticket.test.sh; } > "$LOG" 2>&1 || { cat "$LOG"; exit 1; }
cat > "$OUT/steps.json" <<'J'
{"target":{"version":"bin/jg-beads-write.py add, bin/jg-backlog-transition-lib.sh close, bin/jg-beads-trace.py and bin/jg-beads-moment.py with bin/jg-move.sh"},"start":"an isolated home with a real Beads store, a copy of the ticket tables and ticket listed in its own config/machine-enforce","steps":["add a ticket that already reads building: refused, no row, one refused line, no move","close a ticket that reads intake: refused, row open, task record in place","add, close, answer and drop through their legal moves: row written, one move each","refuse a trace and a moment move: no event and no moment written","check the repository ships no config/machine-enforce"],"result":"each refused move leaves the record unchanged and each legal move writes the record and one move line"}
J
