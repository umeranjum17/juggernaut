#!/usr/bin/env bash
# Live hook for a project whose code this home runs: bring the trunk commit into this
# home's checkout and fast-forward it there, never merging or stashing.
# Usage: jg-trunk-live-home.sh <project-dir> <sha>      (run by `jg-trunk.sh live`)
#
# bin/jg-ff-lib.sh owns the fast-forward guards; a dirty, diverged or wrongly-branched
# home is skipped and this hook exits 1 so the live record says the home did not move.
# The LAST line this hook prints on a failure is its reason; `jg-trunk.sh live` prints it and records it as
# hook-failed:<reason> in data/trunk-live.tsv.
# The one backward move is the pin-back after a red CI (below): the home returns to an earlier trunk commit.
# It does not restart Squad Leads or rerun the stack: that cost is a separate step.
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
fetch_trunk() { local err; err=$(git -C "$JG_ROOT" fetch -q "$PROJECT_DIR" "refs/heads/$TRUNK" 2>&1) || fail_with "cannot fetch $TRUNK from the project: $(printf '%s' "$err" | tail -n 1)"; }
git -C "$JG_ROOT" cat-file -e "$TARGET^{commit}" 2>/dev/null || fetch_trunk
# Pin-back: a target the home is already past moves it BACK, only when the home's HEAD is wholly on
# the trunk (nothing unlanded is dropped) and its tree is clean; a red CI is why this exists.
if [ "$(git -C "$JG_ROOT" rev-parse HEAD)" != "$TARGET" ] && git -C "$JG_ROOT" merge-base --is-ancestor "$TARGET" HEAD \
  && git -C "$JG_ROOT" merge-base --is-ancestor HEAD "$(git -C "$PROJECT_DIR" rev-parse "refs/heads/$TRUNK")"; then
  [ -z "$(git -C "$JG_ROOT" status --porcelain)" ] || fail_with "pin-back skipped: the home has uncommitted changes"
  fetch_trunk
  git -C "$JG_ROOT" reset -q --hard "$TARGET"
  exit
fi
# ff_target sets FF_STATUS in this shell, so its lines go through a file, not a substitution.
ff_log=$(mktemp); trap 'rm -f -- "$ff_log"' EXIT
ff_target "$JG_ROOT" juggernaut "$TARGET" yes no > "$ff_log"
cat "$ff_log"
[ "$FF_STATUS" != skipped ] || fail_with "$(sed -n 's/^[^:]*: skipped: //p' "$ff_log" | head -n 1)"
