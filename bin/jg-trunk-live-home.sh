#!/usr/bin/env bash
# Live hook for a project whose code this home runs: bring the trunk commit into this
# home's checkout and fast-forward it there, never merging or stashing.
# Usage: jg-trunk-live-home.sh <project-dir> <sha>      (run by `jg-trunk.sh live`)
#
# bin/jg-ff-lib.sh owns the fast-forward guards; a dirty, diverged or wrongly-branched
# home is skipped and this hook exits 1 so the live record says the home did not move.
# The LAST line this hook prints on a failure is its reason; `jg-trunk.sh live` prints it and records it as
# hook-failed:<reason> in data/trunk-in-use.tsv.
# The one backward move is the pin-back after a red CI (below): the home returns to an earlier trunk commit.
# It does not restart Squad Leads or rerun the stack: that cost is a separate step.
# After the home stands on the commit it runs bin/jg-host-wiring.sh --changed from that checkout, so every host copy a
# wiring step installs equals its source at the moved-to commit (a step whose sources did not change and whose copies
# match runs nothing). A step that fails leaves the home moved but is this hook's failure: the last line names the steps,
# so the live record says the host is not whole instead of In use. JG_HOST_WIRING_SKIP=1 turns the wiring off for a fixture.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
# shellcheck source=bin/jg-ff-lib.sh
. "$SCRIPT_DIR/jg-ff-lib.sh"
# shellcheck source=bin/jg-trunk-policy-lib.sh
. "$SCRIPT_DIR/jg-trunk-policy-lib.sh"
[ "$#" -eq 2 ] || { sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 2; }
fail_with() { echo "$*" >&2; exit 1; }
PROJECT_DIR=$1 TARGET=$2
TRUNK=$(jg_trunk_branch "$(basename "$PROJECT_DIR")" "${JG_STATE_OVERRIDE:-$JG_HOME/state}")
wire_host() {  # the host copies follow the code the home now holds
  local out rc=0 steps
  [ "${JG_HOST_WIRING_SKIP:-0}" != 1 ] && [ -x "$JG_ROOT/bin/jg-host-wiring.sh" ] || return 0
  out=$(env -u JG_STATE_OVERRIDE -u JG_DATA_OVERRIDE -u JG_CONFIG_OVERRIDE JG_HOME="$JG_HOME" JG_ROOT_OVERRIDE="$JG_ROOT" \
    "$JG_ROOT/bin/jg-host-wiring.sh" --changed "$JG_HOME" 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  [ "$rc" -ne 0 ] || return 0
  steps=$(printf '%s\n' "$out" | sed -n 's/.*, failed: *//p' | tail -n 1 | tr -s ' ' ',')
  fail_with "the home moved but host wiring is not whole: ${steps:-exit $rc} failed"
}
fetch_trunk() { local err; err=$(git -C "$JG_ROOT" fetch -q "$PROJECT_DIR" "refs/heads/$TRUNK" 2>&1) || fail_with "cannot fetch $TRUNK from the project: $(printf '%s' "$err" | tail -n 1)"; }
git -C "$JG_ROOT" cat-file -e "$TARGET^{commit}" 2>/dev/null || fetch_trunk
# Pin-back: a target the home is already past moves it BACK, only when the home's HEAD is wholly on
# the trunk (nothing unlanded is dropped) and its tree is clean; a red CI is why this exists.
if [ "$(git -C "$JG_ROOT" rev-parse HEAD)" != "$TARGET" ] && git -C "$JG_ROOT" merge-base --is-ancestor "$TARGET" HEAD \
  && git -C "$JG_ROOT" merge-base --is-ancestor HEAD "$(git -C "$PROJECT_DIR" rev-parse "refs/heads/$TRUNK")"; then
  [ -z "$(git -C "$JG_ROOT" status --porcelain)" ] || fail_with "pin-back skipped: the home has uncommitted changes"
  fetch_trunk
  git -C "$JG_ROOT" reset -q --hard "$TARGET"
  echo "juggernaut: moved to $TARGET"
  wire_host
  exit
fi
# ff_target sets FF_STATUS in this shell, so its lines go through a file, not a substitution.
ff_log=$(mktemp); trap 'rm -f -- "$ff_log"' EXIT
JG_TRUNK_LIVE=1 JG_TRUNK_TIP="$TARGET" ff_target "$JG_ROOT" juggernaut "$TARGET" yes no > "$ff_log"
cat "$ff_log"
[ "$FF_STATUS" != skipped ] || fail_with "$(sed -n 's/^[^:]*: skipped: //p' "$ff_log" | head -n 1)"
echo "juggernaut: at $(git -C "$JG_ROOT" rev-parse HEAD)"
wire_host
