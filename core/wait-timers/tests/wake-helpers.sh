# The wait-timers test's shared helpers: the same ones every other wake test uses,
# reached from this directory. It exists here because this suite runs on its own
# (bin/jg-test-run.sh runs tests/<name>.test.sh), and a suite that cannot find its
# own harness proves nothing about the wait path it covers.
# shellcheck shell=bash
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
export ROOT
# shellcheck source=/dev/null
. "$ROOT/tests/wake-helpers.sh"
