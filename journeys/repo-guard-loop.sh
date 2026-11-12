#!/usr/bin/env bash
# Journey: the installed gh shim cannot call itself. Runs the loop test and the repo-guard test, and records the steps for the judge.
set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export JG_TEST_FORK="$root" JG_CODE_ROOT="$root"
out="$DONE_DONE_EVIDENCE_ROOT/repo-guard-loop.log"
rc=0
{
  bash "$root/core/repo-guard/tests/loop.test.sh" || rc=1
  bash "$root/core/repo-guard/tests/repo-guard.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a throwaway home with the real repo-guard shim installed over a gh that runs gh by name, and the shim folder first on PATH",
 "steps": ["call gh --version with no other gh on PATH and require an exit inside the 8 s bound that names the cause", "call gh --version with another gh further down PATH and require that gh to answer", "run the existing repo-guard journey and require it to pass"],
 "result": "a gh that calls itself refuses at once instead of looping for ever, a second entry runs the next gh on PATH by its full path, and the guard still refuses a write outside the allow-list"}
JSON
exit "$rc"
