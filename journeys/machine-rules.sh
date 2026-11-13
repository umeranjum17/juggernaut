#!/usr/bin/env bash
# done-done journey: the real bin/jg-machine.sh lints every shipped table and refuses each defect of the rule of section 6.12
# (tests/jg-machine-lint.test.sh), then its report-only `writers` command names each edge whose writer file calls neither
# the shadow nor the move command (tests/jg-machine-writer-lint.test.sh).
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-run}.log
cd "$REPO" || exit 1
{
  for f in core/machines/tables/*.tsv; do bash bin/jg-machine.sh check "$(basename "$f" .tsv)" || exit 1; done
  bash tests/jg-machine-lint.test.sh && bash tests/jg-machine-writer-lint.test.sh
} > "$LOG" 2>&1 || { cat "$LOG"; exit 1; }
cat > "$OUT/steps.json" <<J
{"target":{"version":"$(git rev-parse --short HEAD)"},"start":"fixture machine tables and a fixture repo whose writer files report, or do not report, their moves","steps":["lint every shipped table and each defect of the rule","run jg-machine.sh writers on a table with a reporting writer, a silent writer and a missing writer file","run it on every shipped table"],"result":"each silent or missing writer is named with its edge, a reporting writer is not, and the report exits 0 on every shipped table"}
J
