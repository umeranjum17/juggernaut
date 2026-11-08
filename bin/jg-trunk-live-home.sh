#!/usr/bin/env bash
# Live hook for a project whose code this home runs: bring the trunk commit into this
# home's checkout and fast-forward it there, never merging or stashing.
# Usage: jg-trunk-live-home.sh <project-dir> <sha>      (run by `jg-trunk.sh live`)
#
# bin/jg-ff-lib.sh owns the fast-forward guards; a dirty, diverged or wrongly-branched
# home is skipped and this hook exits 1 so the live record says the home did not move.
# The one backward move is the pin-back after a red CI (below): the home returns to an earlier trunk commit.
# It does not restart Squad Leads or rerun the stack: that cost is a separate step.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
# shellcheck source=bin/jg-ff-lib.sh
. "$SCRIPT_DIR/jg-ff-lib.sh"
[ "$#" -eq 2 ] || { sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 2; }
git -C "$JG_ROOT" cat-file -e "$2^{commit}" 2>/dev/null || git -C "$JG_ROOT" fetch -q "$1" "refs/heads/${JG_TRUNK_BRANCH:-trunk}" || { echo "cannot fetch $2 from $1" >&2; exit 1; }
# Pin-back: a target the home is already past moves it BACK, only when the home's HEAD is wholly on
# the trunk (nothing unlanded is dropped) and its tree is clean; a red CI is why this exists.
if [ "$(git -C "$JG_ROOT" rev-parse HEAD)" != "$2" ] && git -C "$JG_ROOT" merge-base --is-ancestor "$2" HEAD \
  && git -C "$JG_ROOT" merge-base --is-ancestor HEAD "$(git -C "$1" rev-parse "refs/heads/${JG_TRUNK_BRANCH:-trunk}")"; then
  [ -z "$(git -C "$JG_ROOT" status --porcelain)" ] || { echo "pin-back skipped: the home has uncommitted changes" >&2; exit 1; }
  git -C "$JG_ROOT" fetch -q "$1" "refs/heads/${JG_TRUNK_BRANCH:-trunk}" && git -C "$JG_ROOT" reset -q --hard "$2"
  exit
fi
ff_target "$JG_ROOT" juggernaut "$2" yes no
[ "$FF_STATUS" != skipped ]
