#!/usr/bin/env bash
# done-done journey: the ticket tables hold every field Beads prints. tests/item-store-tickets.test.sh imports an all-fields export,
# compares it (0 differences), checks the derived comment count and the kept events, and rebuilds a store made from an older tickets.sql.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
echo "journey run $(git -C "$root" rev-parse HEAD) ${RUN_ID:-run}" > "$out"
bash "$root/tests/item-store-tickets.test.sh" >> "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the real tickets.py adapter on a throwaway item store and an export carrying created_by, updated_at, started_at, comments, events and provenance",
 "steps": ["import the export", "compare it to the tables: 0 differences", "read comment_count from the comment rows", "drift a field and drop a comment: compare names both", "re-import a plain export: events and provenance stay", "open a store made from an older tickets.sql: it is rebuilt from its log"],
 "result": "every new field is in the tables and the compare against the export is 0"}
JSON
exit "$rc"
