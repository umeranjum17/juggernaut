#!/usr/bin/env bash
# E2E: a task bound to a pull request that was closed unmerged may take a receipt for another open pull request only
# when that copy carries a patch-equivalent of every commit the closed one had. Real commits in real repositories;
# only the forge read is stubbed. Two directions: a rebased copy is accepted; a copy with one altered or missing
# commit, a merged predecessor, or a still-open predecessor is refused.
# Usage: core/receipts/tests/receipt-superseded-copy.test.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$here/../../.." && pwd -P)
d=$(mktemp -d "${TMPDIR:-/tmp}/superseded.XXXXXX") || exit 1
trap 'rm -rf -- "$d"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export HOME=$d/home TMPDIR=$d JG_HOME=$d/jg JG_CORE_DIR=$ROOT/core GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$HOME" "$JG_HOME/state"
# shellcheck disable=SC1091  # $ROOT resolves at run time
. "$ROOT/bin/jg-dod-lib.sh"
g() { git -c user.email=t@example.com -c user.name=t -C "$1" "${@:2}"; }
origin=$d/origin.git proj=$d/proj
git init -q --bare "$origin"
git init -q "$proj" && g "$proj" remote add origin "$origin"
w() { printf '%s\n' "$2" > "$1/$3"; g "$1" add "$3"; g "$1" commit -q -m "$4"; }
w "$proj" base f0 "base"; g "$proj" branch -M c4; g "$proj" push -q origin c4
# The closed predecessor: two commits on c4.
g "$proj" checkout -q -b pred; w "$proj" one a "add a"; w "$proj" two b "add b"
pred=$(g "$proj" rev-parse HEAD); g "$proj" push -q origin pred
# c5 moved on; copies are built on it.
g "$proj" checkout -q c4; w "$proj" c5only z "c5 only"; g "$proj" branch -M c5; g "$proj" push -q origin c5
mk() { # <branch> <how>: a copy of pred on c5
  g "$proj" checkout -q -b "$1" c5
  case $2 in
    same) g "$proj" cherry-pick pred~1 pred >/dev/null ;;
    altered) g "$proj" cherry-pick pred~1 >/dev/null; printf 'changed\n' > "$proj/b"; g "$proj" add b; g "$proj" commit -q -m "add b differently" ;;
    missing) g "$proj" cherry-pick pred >/dev/null ;;
    extra) g "$proj" cherry-pick pred~1 pred >/dev/null; w "$proj" more m "an extra commit" ;;
  esac
  g "$proj" push -q origin "$1"; g "$proj" rev-parse HEAD
}
same=$(mk same same); altered=$(mk altered altered); missing=$(mk missing missing); extra=$(mk extra extra)
[ "$same" != "$pred" ] || fail "fixture: the copy kept the SHAs"
meta=$JG_HOME/state/t.meta
printf 'project=%s\nbase_branch=c4\npr_head=%s\n' "$proj" "$pred" > "$meta"
pr1=https://github.com/o/r/pull/1 pr2=https://github.com/o/r/pull/2
PRED_STATE=CLOSED PRED_MERGED=false MERGED_NOTE=no
# shellcheck disable=SC2317,SC2329  # called by the acceptance
jg_pr_poll_merge_already_notified() { [ "$MERGED_NOTE" = yes ]; }
# shellcheck disable=SC2317,SC2329,SC2034
jg_pr_github_read_record() {  # shellcheck disable=SC2034
  if [ "$3" = 1 ]; then JG_PR_RECORD_STATE=$PRED_STATE JG_PR_RECORD_MERGED=$PRED_MERGED
  else JG_PR_RECORD_STATE=OPEN JG_PR_RECORD_MERGED=false; fi
}
ok() { jg_receipts_next_pr_of_lane_ok "$JG_HOME/state" t "$pr1" "$pr2" "$meta" "$1"; }
ok "$same" || fail "a rebased copy with every commit equivalent must be accepted"
ok "$altered" && fail "a copy with one altered commit must be refused"
ok "$missing" && fail "a copy missing one commit must be refused"
ok "$extra" || fail "a copy that carries every commit plus more still carries the work"
ok "" && fail "no candidate head must be refused"
PRED_STATE=OPEN; ok "$same" && fail "a still-open predecessor must be refused"
PRED_STATE=CLOSED PRED_MERGED=true; ok "$same" && fail "a merged-and-closed predecessor must be refused"
PRED_MERGED=false
jg_receipts_next_pr_of_lane_ok "$JG_HOME/state" t "$pr1" "$pr2" && fail "callers that pass no candidate keep the old rule"
MERGED_NOTE=yes; jg_receipts_next_pr_of_lane_ok "$JG_HOME/state" t "$pr1" "$pr2" || fail "the merged-predecessor path is unchanged"
echo "ok - superseded copy: rebased copy accepted; altered, missing, merged and open predecessors refused"
