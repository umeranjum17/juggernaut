#!/usr/bin/env bash
# The tier runner on the real done-done: bin/jg-tier-run.sh ci runs a real tier-ci journey by name (the one-journey
# tier below) and exits 0, where `done-done run --tier ci` alone exits 2 with "run needs a journey".
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${DONE_DONE_EVIDENCE_ROOT:?}"
d="$(mktemp -d)"; trap 'rm -rf -- "$d"' EXIT
printf 'journeys:\n  contract-agents-md-floor:\n    tier: ci\n' >"$d/cfg.yaml"
{
  echo "== before: done-done run --tier ci"
  (cd "$ROOT" && GITHUB_ACTIONS=true done-done run --tier ci) 2>&1 || echo "exit $? (expected 2)"
  echo "== after: bin/jg-tier-run.sh ci"
  (cd "$ROOT" && JG_TIER_CONFIG="$d/cfg.yaml" GITHUB_ACTIONS=true bin/jg-tier-run.sh ci) 2>&1
  echo "exit $?"
  echo "== tests/jg-tier-run.test.sh"
  bash "$ROOT/tests/jg-tier-run.test.sh"
} >"$out/${DONE_DONE_RUN_ID:-run}.log" 2>&1
printf '{"target":{"version":"jg-tier-run"},"start":"CI step done-done run --tier ci stops with exit 2","steps":["run bin/jg-tier-run.sh ci"],"result":"the tier journey ran by name and the runner exited 0"}\n' >"$out/steps.json"
