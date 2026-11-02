#!/usr/bin/env bash
# Owner of test-fixture removal for the lead-wake journeys. Usage:
#   fixture-cleanup.sh <path>
# A watcher leaves a detached helper (home-summary refresh, reconcile) running
# when a journey stops it, and that helper can recreate the fixture's state
# directory after the run ends. One `rm -rf` then walks a tree that is being
# refilled and fails with "Directory not empty", which under an EXIT trap turns
# a fully green journey into exit 1. Retrying the removal while the tree is
# still being filled absorbs the late write, and a path that will not go is
# reported by name. Cleanup never fails the run it belongs to: it exits 0.
set -uo pipefail
path=${1:-}
[ -n "$path" ] || exit 0
i=0
# Each pass removes the tree, then waits one beat for a late writer to land
# before deciding it is gone; a writer that keeps filling it is bounded here.
while [ -e "$path" ] && [ "$i" -lt 20 ]; do
  rm -rf -- "$path" 2>/dev/null || true
  sleep 0.1
  i=$((i + 1))
done
[ ! -e "$path" ] || printf 'warning: fixture cleanup left %s\n' "$path" >&2
exit 0
