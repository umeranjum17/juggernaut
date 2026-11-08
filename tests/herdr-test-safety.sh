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

# herdr_test_require_beads: a spawn reads the home's backlog first and refuses a task with no ticket in a
# Beads store, so a suite that drives the real jg-spawn.sh needs the pinned bd and dolt. Skips plainly
# without them, as every Beads fixture suite does (tests/lib.sh jg_test_beads_home).
herdr_test_require_beads() {
  JG_BEADS_BD=${JG_BEADS_TEST_BD:-$(command -v bd 2>/dev/null || true)}
  JG_BEADS_DOLT=${JG_BEADS_TEST_DOLT:-$(command -v dolt 2>/dev/null || true)}
  if [ -z "$JG_BEADS_BD" ] || [ -z "$JG_BEADS_DOLT" ]; then
    echo "skip: no Beads store: bd and dolt are not installed (JG_BEADS_TEST_BD, JG_BEADS_TEST_DOLT)"
    return 1
  fi
  export JG_BEADS_BD JG_BEADS_DOLT
  # An operator shell may export BEADS_DIR at its live store; a fixture home addresses only its own.
  unset BEADS_DIR BEADS_DB BEADS_DOLT_SHARED_SERVER
}

# herdr_test_backlog_ticket <home> <id>: leave the fixture task as a queued ticket in the home's own Beads
# store, building the store beside the home on first use. A Beads id has a prefix and a hyphen. A task that
# an earlier spawn and teardown in the same suite already finished is reopened, since spawn dispatches only
# queued work.
herdr_test_backlog_ticket() {
  local home=$1 id=$2 store shown state
  if [ ! -s "$home/config/beads-dir" ]; then
    store=$home-store
    mkdir -p "$home/config" "$store" || return 1
    BEADS_DIR=$store/.beads "$HERDR_TEST_SAFETY_DIR/bin/jg-beads.sh" init --prefix jg >/dev/null 2>&1 || {
      echo "not ok - could not initialise the Beads store for $home" >&2
      return 1
    }
    printf '%s\n' "$store/.beads" > "$home/config/beads-dir"
  fi
  (
    cd "$home" || exit 1
    export JG_HOME="$home" JG_CONFIG_OVERRIDE="$home/config" JG_TASK_PRIORITY_CHECK=/nonexistent
    backlog="$HERDR_TEST_SAFETY_DIR/bin/jg-backlog.sh"
    if shown=$("$backlog" show "$id" 2>/dev/null); then
      state=$(printf '%s\n' "$shown" | awk '$1 == "state:" { print $2; exit }')
      [ "$state" = queued ] || "$backlog" reopen "$id" >/dev/null 2>&1
    else
      "$backlog" add "$id" "[feature] Herdr fixture $id" --priority 1 --kind ship --repo demo \
        --body "Fixture ticket $id" >/dev/null 2>&1
    fi
  ) || {
    echo "not ok - could not leave fixture ticket $id queued in $home" >&2
    return 1
  }
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
