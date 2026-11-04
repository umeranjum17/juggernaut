#!/usr/bin/env bash
# A red CI run files one root-cause ticket instead of a re-run: runs the end-to-end suite of the watcher check
# (core/merge-on-green/tests/red-ci-ticket.test.sh) in the fast set, so a change to journeys/red-ci-ticket.sh
# or the check is exercised before merge. The suite drives the real red-ci-ticket.sh against a recorded forge.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
bash "$ROOT/core/merge-on-green/tests/red-ci-ticket.test.sh"
