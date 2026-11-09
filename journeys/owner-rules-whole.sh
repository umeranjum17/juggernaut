#!/usr/bin/env bash
# Capture the real startup reader over local memory beyond the digest's byte caps: long curated files print a bounded excerpt with a pointer, and a lifted cap prints every byte.
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
 "steps":["Run the real session-start command with default caps.","Check the whole digest stays under its 40000-byte cap.","Check each long file prints a bounded excerpt, a cut line with its line range and the sed command that prints the rest, and the owner rules print as an index of every rule's title.","Repeat startup with the caps lifted and compare every owner-rule and captain source byte with the printed body.","Compare hashes of every source memory file before and after startup.","Check absent and empty memory markers in the existing startup fixture.","Run the learnings-index journey to prove the heading index, its count and its body readers."],
 "result":"Under default caps the digest stays under its byte cap, every cut names what it hides and the command that prints it, and every owner rule is reachable through the index; with the caps lifted every owner-rule body prints in full; source files stay unchanged."}
JSON
