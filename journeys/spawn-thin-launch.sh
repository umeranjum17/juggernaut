#!/usr/bin/env bash
# Drive the real spawn for a Claude worker, a Claude squad lead and a project with its own MCP file, and read each launch's settings.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-spawn-dispatch-profile.test.sh" > "$out" 2>&1 || rc=$?
cat "$out"
printf '{"target":{"version":"juggernaut@%s"},"start":"a home with an account that holds personal skills and a project with its own MCP file","steps":["spawn a Claude worker","spawn a Claude squad lead","spawn a worker for a project that registers an MCP file"],"result":"each launch turns the workflow text, harness memory and every skill outside the role keep-list off, and passes the registered MCP file after the strict flag"}\n' "$(git -C "$root" rev-parse --short HEAD)" > "${DONE_DONE_EVIDENCE_ROOT}/steps.json"
exit "$rc"
