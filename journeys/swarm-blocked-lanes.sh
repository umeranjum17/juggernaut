#!/usr/bin/env bash
# Verify the real swarm check and delivery claim against isolated Main and lead homes.
set -eu
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/swarm-blocked-lanes.log
{
  bash "$root/bin/jg-lint.sh" --changed-base HEAD^ &&
  bash "$root/bin/jg-doc-audience-check.sh" &&
  bash "$root/tests/jg-go-entries.test.sh" &&
  bash "$root/tests/jg-delivery-record.test.sh" &&
  bash "$root/tests/jg-swarm-check.test.sh"
} > "$out" 2>&1 || { cat "$out"; exit 1; }
cat "$out"
