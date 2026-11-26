#!/usr/bin/env bash
# Retain the real objective journey's output in the run done-done gives it.
set -euo pipefail
node journeys/run.ts "$1" | tee "$DONE_DONE_EVIDENCE_ROOT/$1.log"
