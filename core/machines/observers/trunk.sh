#!/usr/bin/env bash
# trunk.sh - report-only observer of the trunk line machine (core/machines/tables/trunk.tsv): one word per project trunk.
#
# Usage: trunk.sh <project>   print clean, unverified, verifying or red; print nothing when the project has no trunk tip record
# Records read, never written:
#   state/trunk-tip-<project>, state/trunk-green-<project>   the tip and the green pin (bin/jg-trunk.sh)
#   state/.trunk-verify-<project>.lock/pid                   the verify slot: a live pid there means a verify runs
#   data/trunk-ci.tsv                                        project, commit, epoch, red|green[, source]: a charged red
#   projects/<project>                                       the clone, to tell whether a red commit is on the tip and not yet reverted
# The word:
#   clean        the tip is the green pin
#   red          a red row names a commit above the pin that is on the tip, and no commit after it says `reverts: <commit>`
#   verifying    the tip is above the pin and the verify lock is held by a live process
#   unverified   the tip is above the pin and nothing else holds
set -u
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}; DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
p=${1:-}; [ -n "$p" ] || { echo "usage: trunk.sh <project>" >&2; exit 2; }
rd() { cat "$STATE/$1-$p" 2>/dev/null || true; }
tip=$(rd trunk-tip); green=$(rd trunk-green)
[ -n "$tip" ] || exit 0
[ "$tip" != "$green" ] || { echo clean; exit 0; }

# A red commit that holds the pin down: on the tip, above the pin, and not reverted by a later commit.
blocking_red() {
  local repo=$JG_HOME/projects/$p r
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 1
  while IFS= read -r r; do
    git -C "$repo" merge-base --is-ancestor "$r" "$tip" 2>/dev/null || continue
    [ -z "$green" ] || ! git -C "$repo" merge-base --is-ancestor "$r" "$green" 2>/dev/null || continue
    git -C "$repo" log --format=%B "$r..$tip" | grep -qx "reverts: $r" && continue
    return 0
  done < <(awk -F'\t' -v p="$p" '$1 == p && $4 == "red" { print $2 }' "$DATA/trunk-ci.tsv" 2>/dev/null | sort -u)
  return 1
}
verify_pid=$(cat "$STATE/.trunk-verify-$p.lock/pid" 2>/dev/null || true)
if blocking_red; then echo red
elif [ -n "$verify_pid" ] && kill -0 "$verify_pid" 2>/dev/null; then echo verifying
else echo unverified; fi
