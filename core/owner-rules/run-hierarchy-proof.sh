#!/usr/bin/env bash
# Drive the hierarchy rule through the fork's real jg-brief.sh and record the done-done journey.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
fork=${JG_TEST_FORK:-}
[ -n "$fork" ] && [ -x "$fork/bin/jg-brief.sh" ] \
  || { echo "owner-rules hierarchy proof: set JG_TEST_FORK to a Juggernaut checkout with the brief-inherit seam" >&2; exit 1; }
[ -n "${DONE_DONE_EVIDENCE_ROOT:-}" ] && [ -n "${DONE_DONE_RUN_ID:-}" ] \
  || { echo "owner-rules hierarchy proof: run through done-done" >&2; exit 1; }
target=$(git -C "$repo" rev-parse --short HEAD)
jq -n --arg version "$target" \
  '{target:{version:$version},start:"A disposable home has the owner-rules feature installed and a fixture backlog.",steps:["Brief an owner-linked lane without a parent and confirm it is refused before a brief is written.","Brief items with an existing parent and with parent: upkeep, then inspect their generated briefs.","Run the read-only tree helper and inspect its epic chain, missing-id and cycle reports."],result:"The lane brief enforces backlog hierarchy and the tree helper shows valid and invalid parent chains."}' \
  > "$DONE_DONE_EVIDENCE_ROOT/steps.json"
log="$DONE_DONE_EVIDENCE_ROOT/${DONE_DONE_RUN_ID}.log"
bash "$repo/owner-rules/tests/owner-rules.test.sh" "$fork" > "$log" 2>&1
cat "$log"
