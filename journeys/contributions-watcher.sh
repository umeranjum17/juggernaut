#!/usr/bin/env bash
# Capture the real watcher settling a busy contribution history.
set -eu
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
out=${DONE_DONE_EVIDENCE_ROOT:?}
rc=0
bash "$root/tests/jg-contributions.test.sh" > "$out/contributions-watcher.log" 2>&1 || rc=$?
cat "$out/contributions-watcher.log"
[ "$rc" -eq 0 ] || exit "$rc"
jq -n --arg version "$(git -C "$root" rev-parse HEAD)" \
  --rawfile result "$out/contributions-watcher.log" '{
    target:{version:$version},
    start:"An isolated home with 900 final contributions and a recorded check failure",
    steps:["Register the contributions check", "Arm the watcher with its 30-second check limit",
      "Read the resulting failure streak and the saved records for both owners"],
    result:($result | rtrimstr("\n"))
  }' > "$out/steps.json"
