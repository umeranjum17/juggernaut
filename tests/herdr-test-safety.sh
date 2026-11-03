#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/jg-herdr-lab.sh.
set -u

# shellcheck source=tests/git-config-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-config-helpers.sh"

# Herdr backend tests drive the real jg-spawn/jg-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/jg-gate-refuse-lib.sh for why juggernaut's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export JG_GATE_REFUSE_BYPASS=1

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_TEST_SAFETY_DIR/bin/jg-herdr-lab.sh"

# herdr_forget_inherited_pane: drop the Herdr PANE identity this test process
# inherited from whatever terminal it was started in.
#
# Herdr injects HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH, and HERDR_SESSION into every process it manages a pane for
# (verified 0.7.5 - docs/verification/runtime-backends.md), and a test run from
# inside a Herdr pane inherits all of them. Spawn now treats that pane as the
# authoritative parent to place workers next to, so a leaked identity from the
# developer's own session would follow the test into its isolated lab session
# and be refused there as a cross-session parent - a result that depends on
# where the suite was launched from, not on what it asserts.
#
# Call this before exporting the lab HERDR_SESSION in any suite whose subject is
# the per-home container path. A suite that means to exercise a launcher-bound
# spawn sets HERDR_PANE_ID itself, to a pane it created in its own lab session.
herdr_forget_inherited_pane() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

HERDR_TEST_FLEET_ENV=(-u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME "HOME=$HOME")
for herdr_test_key in XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME; do
  if [ "${!herdr_test_key+x}" = x ]; then
    HERDR_TEST_FLEET_ENV+=("$herdr_test_key=${!herdr_test_key}")
  fi
done
unset herdr_test_key

herdr_prepare_runtime() {
  jg_herdr_lab_prepare "$1" || return 1
  jg_herdr_lab_runtime_env "$1"
}

herdr_safe_stop_and_delete() { # <session>
  env "${HERDR_TEST_FLEET_ENV[@]}" bash "$HERDR_TEST_SAFETY_DIR/bin/jg-herdr-lab.sh" teardown "$1"
}
