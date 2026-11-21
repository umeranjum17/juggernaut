#!/usr/bin/env bash
# done-done journey: fleet.db under parallel writers and over time (jg-ih7). The real jg-item, bd_compat.py and tickets.py run
# in throwaway homes: writers behind a lock holder past one busy wait, the tick's compaction, and an older store's upgrade;
# the store's own proofs and the ticket readers that read the log run beside it.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
{
  bash "$root/tests/item-store-contention-e2e.test.sh" || rc=1
  bash "$root/tests/item-store.test.sh" || rc=1
  bash "$root/tests/item-store-tickets.test.sh" || rc=1
  bash "$root/tests/bd-compat-create.test.sh" || rc=1
  bash "$root/tests/item-store-ticket-reads.test.sh" || rc=1
  bash "$root/tests/jg-beads-read.test.sh" || rc=1
  bash "$root/tests/jg-model-stats.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "throwaway main homes whose fleet.db holds the item and ticket tables",
 "steps": ["hold the write lock 16 s while 16 jg-item writers and 4 bd_compat ticket writers write", "import four rounds of ticket history, drop a lead home, open an item", "compact as if 8 days passed", "replay the ticket tables from the log that is left", "erase the whole log", "open a store made with the old trigger and no auto-vacuum, then tick"],
 "result": "every write lands with no database-is-locked refusal; compaction erases only aged changes of closed and dropped tickets, every ticket, link, comment, event, item and move row is unchanged and replays from the log, the free pages go back to the disk; the older store takes the new trigger and incremental auto-vacuum"}
JSON
exit "$rc"
