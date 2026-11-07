#!/usr/bin/env bash
# Live hook for a project whose code this home runs: bring the trunk commit into this
# home's checkout and fast-forward it there, never forcing, merging or stashing.
# Usage: jg-trunk-live-home.sh <project-dir> <sha>      (run by `jg-trunk.sh live`)
#
# bin/jg-ff-lib.sh owns the fast-forward guards; a dirty, diverged or wrongly-branched
# home is skipped and this hook exits 1 so the live record says the home did not move.
# It does not restart Squad Leads or rerun the stack: that cost is a separate step.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
# shellcheck source=bin/jg-ff-lib.sh
. "$SCRIPT_DIR/jg-ff-lib.sh"
[ "$#" -eq 2 ] || { sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 2; }
git -C "$JG_ROOT" cat-file -e "$2^{commit}" 2>/dev/null || git -C "$JG_ROOT" fetch -q "$1" "refs/heads/${JG_TRUNK_BRANCH:-trunk}" || { echo "cannot fetch $2 from $1" >&2; exit 1; }
ff_target "$JG_ROOT" juggernaut "$2" yes no
[ "$FF_STATUS" != skipped ]
