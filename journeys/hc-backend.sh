#!/usr/bin/env bash
# The hc (Herdr Core) backend's core primitives and its isolated lab, driven
# against a real Herdr Core: the suite writes hc-backend-e2e.log and
# steps.json into this run's folder. Needs Herdr Core 0.1.18 or newer on PATH.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${DONE_DONE_EVIDENCE_ROOT:?}"
JG_HC_BACKEND_LIVE_E2E=1 exec bash "$root/tests/jg-backend-hc-live-e2e.test.sh"
