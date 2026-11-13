#!/usr/bin/env bash
# Runs one command string from the core tree, the way the retired Core suites job ran each step:
# working directory core/, with the core and its feature suites taken from this exact checkout.
# Usage: journeys/core-run.sh '<command>'   (a chain joined by && stops at its first failure)
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$#" -eq 1 ] || { echo "usage: core-run.sh '<command>'" >&2; exit 2; }
cd "$ROOT/core"
export JG_TEST_FORK="$ROOT" JG_CODE_ROOT="$ROOT"
exec bash -c "$1"
