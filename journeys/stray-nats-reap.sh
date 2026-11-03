#!/usr/bin/env bash
# The stray nats-server reaper: its test starts fake throwaway servers and proves a dry run stops nothing, --stop stops only the old ones in the allowlist, and a live home's bus server is skipped; then one real dry run on this machine lists what it would stop.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${DONE_DONE_RUN_ID:-run}.log
{
  bash "$root/tests/jg-stray-nats-reap.test.sh" || exit 1
  echo "--- dry run on this machine (default allowlist, default minimum age) ---"
  "$root/bin/jg-stray-nats-reap.sh"
} > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a throwaway root holding fake servers named nats-server, one inside a real-home layout; this machine's own process table for the last step",
 "steps": ["run bin/jg-stray-nats-reap.sh with the default minimum age and see every young server skipped", "run it dry with a zero minimum age and see the old servers listed while nothing stops", "run it with --stop and see only the old servers inside the allowlist stop", "run it with no flags on this machine"],
 "result": "the dry run stops nothing, --stop stops the four old servers (absolute config, relative config, store directory alone, dotted path) and leaves a live home's bus server, the JG_HOME server, a server outside the allowlist, a young server and a non-nats process running, a second pass finds nothing, and the no-flag run on this machine lists each nats-server as skipped or would-stop without stopping any"}
JSON
exit "$rc"
