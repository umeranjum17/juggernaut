#!/usr/bin/env bash
# Capture the real startup reader over local memory beyond the former owner-rule cap.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
JG_SESSION_START_ONLY='test_context_digest_absent_empty_present test_context_owner_rules_whole test_learnings_index_and_body_cap' \
  bash "$root/tests/jg-session-start.test.sh" > "$evidence/startup.log" 2>&1
rc=$?
cat "$evidence/startup.log"
[ "$rc" -eq 0 ] || exit "$rc"
cat > "$evidence/steps.json" <<JSON
{"target":{"version":"$(git -C "$root" rev-parse HEAD)"},
 "start":"A throwaway local home has three owner-rule bodies each beyond 10000 bytes and long captain, shared and learnings files.",
 "steps":["Run the real session-start command with default caps.","Compare every owner-rule and captain source byte with the printed body.","Check shared and learnings output uses the 7500-byte cap.","Repeat startup with a 256-byte override and compare again.","Compare hashes of every source memory file before and after startup.","Check absent and empty memory markers in the existing startup fixture.","Run the complete learnings-index journey to prove the landed index and its body cap remain intact."],
 "result":"Every local owner-rule body prints in full under both cap settings; captain remains whole, shared and learnings stay capped, and source files stay unchanged."}
JSON
