#!/usr/bin/env bash
# The local trunk flow: one proved commit per ticket lands on a local trunk branch and is
# live at once, and the accumulated trunk goes out in one batch release.
#
# Usage: jg-trunk.sh init <project-dir> [<base-ref>]   create the trunk (default: the newest release/c-N, else HEAD)
#        jg-trunk.sh land <task-id>                    land the task's one commit, then go live
#        jg-trunk.sh verify <project-dir>              run the full suite at the trunk tip: green moves the pin, red stops landings
#        jg-trunk.sh live <project-dir>                move the home to the last fully green commit
#        jg-trunk.sh release <project-dir>             push the batch to the next release/c-N and open the one release PR
#        jg-trunk.sh due <project-dir>                 exit 0 when the oldest unreleased commit is past release-after-hours
#
# The trunk is the project's newest trunk-v<N> branch, falling back to `trunk`.
#
# The ship branch (state/<id>.meta branch=, default fm/<id>) must hold EXACTLY ONE commit on
# top of the trunk tip. A moved tip or a second commit refuses; the lane rebases and proves again.
# `land` runs the same gates as bin/jg-merge-local.sh (bin/jg-merge-gate-lib.sh owns them), plus
# the linked-decision block, then the lander's own gate at the candidate's exact tree in a clean
# clone, then moves the trunk with a compare-and-swap `update-ref`, so a racing lander or a lane
# that moved the ref is refused rather than overwritten. The trunk tip is recorded in
# state/trunk-tip-<project>; a tip that differs from that record was moved by someone other than
# this script (a lane can `git branch -f`), and every subcommand refuses until it is explained.
# Only the lander moves the trunk. A worker never lands.
#
# Pin-back: state/trunk-green-<project> is the last commit that passed the FULL suite. `live`
# moves the home only to that commit, so a smoke-only landing is not live until `verify` passes.
# A red `verify` writes state/trunk-red-<project>; while it exists only a commit whose message
# has the line `fixes-red: <red sha>` may land, and `release` refuses.
#
# Exit 3 means the commit IS on the trunk but the home did not move (the live hook failed).
#
# Every open captain call is a key in bin/jg-trunk-policy-lib.sh with its safe default; nothing
# here changes with the answer. Records: data/trunk-landings.tsv (task, project, commit, epoch,
# gate), data/trunk-live.tsv (project, commit, epoch, status), data/trunk-releases.tsv.
# `live` runs config/live-hook.<project> <project-dir> <sha> when it is executable. With none, a
# project that shares this home's code origin is moved by bin/jg-trunk-live-home.sh; any other
# project is recorded as landed but not live.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-dod-lib.sh
. "$SCRIPT_DIR/jg-dod-lib.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-lease-lib.sh
. "$SCRIPT_DIR/jg-lease-lib.sh"
# shellcheck source=bin/jg-version-branch-lib.sh
. "$SCRIPT_DIR/jg-version-branch-lib.sh"
# shellcheck source=bin/jg-trunk-policy-lib.sh
. "$SCRIPT_DIR/jg-trunk-policy-lib.sh"
export JG_HOME JG_CONFIG_OVERRIDE="$CONFIG"

usage() { sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d'; }
die() { echo "error: $*" >&2; exit 1; }
refuse() { echo "REFUSED: $*" >&2; exit 1; }
pol() { jg_trunk_policy "$1" "${PN:-}"; }
put() { printf '%s\n' "$2" > "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"; }
row() { mkdir -p "$DATA"; local f=$1; shift; printf '%s\n' "$(IFS=$'\t'; echo "$*")" >> "$DATA/$f"; }
rev() { git -C "$PROJ" rev-parse --verify --quiet "$1^{commit}"; }

LOCKS=''
cleanup() { local l; for l in $LOCKS; do jg_lock_release "$l" || true; done; [ -z "${WORK:-}" ] || rm -rf -- "$WORK"; }
trap cleanup EXIT
lock() { jg_lock_acquire_wait "$1"; LOCKS="$1 $LOCKS"; }

# The project's CURRENT trunk: the newest local trunk-v<N> branch, else the configured name
# (default `trunk`). A project with no trunk at all resolves to the plain name, so tip_ok keeps
# its exact "no trunk for <project>" refusal.
current_trunk() {
  git -C "$PROJ" for-each-ref --format='%(refname:strip=2)' 'refs/heads/trunk-v*' 2>/dev/null \
    | awk '/^trunk-v[0-9]+$/ { n = substr($0, 8) + 0; if (!seen || n > best) { best = n; seen = 1; name = $0 } } END { if (seen) print name }' \
    | grep . || pol trunk-branch
}

open_project() {  # <project-dir>: sets PROJ PN TRUNK
  PROJ=${1:?project directory required}
  git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1 || die "$PROJ is not a git repository"
  PN=$(basename "$PROJ")
  TRUNK=$(current_trunk)
  git check-ref-format --branch "$TRUNK" >/dev/null 2>&1 || die "invalid trunk-branch '$TRUNK'"
  export JG_TRUNK_BRANCH=$TRUNK
  [ "$(pol trunk-owner)" = this-home ] || refuse "trunk-owner=$(pol trunk-owner) is not built; only this-home is, and the owner is an open captain call"
}

# The trunk must be where the lander last left it.
tip_ok() {
  local want have
  want=$(cat "$STATE/trunk-tip-$PN" 2>/dev/null) || refuse "no trunk for $PN; run: jg-trunk.sh init $PROJ"
  have=$(rev "refs/heads/$TRUNK") || refuse "trunk branch $TRUNK is missing in $PROJ"
  [ "$want" = "$have" ] || refuse "$TRUNK is at ${have:0:12} but the lander last left it at ${want:0:12}; something else moved it, so nothing lands or releases until that is explained"
}

# Run a gate command at a commit's exact tree in a clean clone; the log is kept under data/.
run_gate() {  # <commit> <command> <label>
  local log="$DATA/trunk/gate-$PN-${1:0:12}-$3.log" rc=0
  mkdir -p "$DATA/trunk"
  WORK=$(mktemp -d)
  git clone -q --shared --no-checkout "$PROJ" "$WORK/tree" || die "cannot clone $PROJ for the gate"
  git -C "$WORK/tree" checkout -q --detach "$1" || die "cannot check out ${1:0:12} for the gate"
  (cd "$WORK/tree" && env -u JG_TASK_ID bash -c "$2") > "$log" 2>&1 || rc=$?
  rm -rf -- "$WORK"; WORK=
  [ "$rc" -eq 0 ] || { tail -n 20 "$log" >&2; refuse "gate '$3' failed (exit $rc) at ${1:0:12}; full log: $log"; }
}

touches_protected() {  # <commit-a> <commit-b>: prints the first protected path the diff touches
  local path glob globs
  read -r -a globs <<< "$(pol protected-paths)"
  while IFS= read -r path; do
    for glob in "${globs[@]}"; do
      # shellcheck disable=SC2254
      case $path in $glob) printf '%s\n' "$path"; return 0 ;; esac
    done
  done < <(git -C "$PROJ" diff --name-only "$1" "$2")
  return 1
}

cmd_init() {
  local base=${2-} vb r
  open_project "${1-}"
  [ ! -e "$STATE/trunk-tip-$PN" ] || die "trunk for $PN already exists"
  if [ -z "$base" ]; then
    base=HEAD; vb=$(jg_current_version_branch "$PROJ" || true)
    for r in ${vb:+"origin/$vb" "$vb"}; do if rev "$r" >/dev/null; then base=$r; break; fi; done
  fi
  base=$(rev "$base") || die "base ref '$base' does not resolve in $PROJ"
  git -C "$PROJ" update-ref -m "trunk: init" "refs/heads/$TRUNK" "$base" ""
  mkdir -p "$STATE"
  put "$STATE/trunk-tip-$PN" "$base"; put "$STATE/trunk-green-$PN" "$base"; put "$STATE/trunk-released-$PN" "$base"
  echo "trunk $TRUNK created at ${base:0:12} in $PROJ"
}

cmd_land() {
  local id=${1-} META branch cand tip n red hit rc=0 linked gate cmd
  jg_pr_task_id_valid "$id" || die "invalid task id"
  META="$STATE/$id.meta"; [ -f "$META" ] || die "no meta for task $id at $META"
  open_project "$(jg_dod_meta_value "$META" project)"
  case $(jg_dod_meta_value "$META" mode) in local-only|trunk) ;; *) die "task $id is not a local-only or trunk task; merge PR tasks with bin/jg-pr-merge.sh" ;; esac
  [ "$(pol owner-rules)" = keep ] || refuse "owner-rules=$(pol owner-rules) is not decided; the owner rule gates keep running until the captain replaces them"
  if [ "$(pol away-landing)" = held ] && [ -e "$STATE/.afk" ]; then refuse "away mode: trunk landings stay held until the captain returns (away-landing=held)"; fi
  jg_lease_forbid_branch "trunk landing (jg-trunk)"
  lock "$STATE/.control-$id.lock"; lock "$STATE/.trunk-$PN.lock"
  tip_ok; tip=$(rev "refs/heads/$TRUNK")
  branch=$(jg_dod_meta_value "$META" branch); branch=${branch:-fm/$id}
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "task $id has an invalid ship branch '$branch'"
  cand=$(rev "refs/heads/$branch") || die "branch $branch does not exist in $PROJ"
  git -C "$PROJ" merge-base --is-ancestor "$tip" "$cand" || refuse "trunk moved: rebase $branch onto $TRUNK (${tip:0:12}) and prove it again"
  n=$(git -C "$PROJ" rev-list --count "$tip..$cand")
  [ "$n" = 1 ] || refuse "one commit per ticket: $branch has $n commits over $TRUNK; squash it to one"
  if [ -e "$STATE/trunk-red-$PN" ]; then
    red=$(cat "$STATE/trunk-red-$PN")
    git -C "$PROJ" log -1 --format=%B "$cand" | grep -qx "fixes-red: $red" || refuse "$TRUNK is red at ${red:0:12}; only a commit with the line 'fixes-red: $red' may land"
  fi
  if hit=$(touches_protected "$tip" "$cand") && [ "$(pol protected-landing)" = refuse ]; then
    refuse "$hit is a protected path; this commit keeps the pull request path (protected-landing=refuse)"
  fi
  linked=$(JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-captain-hold.sh" blocking "$id") || rc=$?
  case $rc in
    0) refuse "task $id is linked to a decision still open for the captain: $(printf '%s' "$linked" | tr '\t\n' ' ;')" ;;
    1) ;;
    *) refuse "could not read the decisions linked to task $id" ;;
  esac
  jg_dod_local_landing_gates "$SCRIPT_DIR" "$CONFIG" "$JG_HOME" "$STATE" "$id" "$META" "$PROJ" "$TRUNK" "$cand" || exit 1
  gate=$(pol gate-mode)
  case $gate in
    full) cmd=$(pol gate-full) ;;
    smoke) cmd=$(pol gate-smoke); [ -n "$cmd" ] || refuse "gate-mode=smoke but no gate-smoke command is chosen" ;;
    *) refuse "unknown gate-mode '$gate'" ;;
  esac
  run_gate "$cand" "$cmd" "$gate"
  git -C "$PROJ" update-ref -m "trunk: land $id" "refs/heads/$TRUNK" "$cand" "$tip" || refuse "$TRUNK changed while landing $id"
  put "$STATE/trunk-tip-$PN" "$cand"
  [ "$gate" != full ] || put "$STATE/trunk-green-$PN" "$cand"
  row trunk-landings.tsv "$id" "$PN" "$cand" "$(date +%s)" "$gate"
  JG_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/jg-ticket.sh" "$id" --stage "done" --state "done" || true
  if declare -F jg_merge_post_hook >/dev/null; then jg_merge_post_hook "$CONFIG" "$JG_HOME" "$id" "$META" "$cand" - >&2; fi
  echo "landed $id on $TRUNK (${tip:0:12} -> ${cand:0:12}, gate=$gate) in $PROJ"
  cmd_live "$PROJ"
}

cmd_verify() {
  local tip rc=0
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok; tip=$(rev "refs/heads/$TRUNK")
  ( run_gate "$tip" "$(pol gate-full)" full ) || rc=$?
  if [ "$rc" -ne 0 ]; then put "$STATE/trunk-red-$PN" "$tip"; echo "trunk is RED at ${tip:0:12}; landings stop except a fixes-red commit" >&2; exit 1; fi
  put "$STATE/trunk-green-$PN" "$tip"; rm -f "$STATE/trunk-red-$PN"
  echo "trunk green at ${tip:0:12}"
}

cmd_live() {
  local green tip hook status=landed-not-live here there
  open_project "${1-}"; tip_ok; tip=$(rev "refs/heads/$TRUNK")
  green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null) || refuse "no fully green trunk commit yet; the home stays where it is"
  hook="$CONFIG/live-hook.$PN"
  if [ ! -x "$hook" ]; then
    here=$(git -C "$JG_ROOT" remote get-url origin 2>/dev/null || echo a); there=$(git -C "$PROJ" remote get-url origin 2>/dev/null || echo b)
    [ "$here" != "$there" ] || hook="$SCRIPT_DIR/jg-trunk-live-home.sh"
  fi
  if [ -x "$hook" ]; then
    "$hook" "$PROJ" "$green" || { row trunk-live.tsv "$PN" "$green" "$(date +%s)" hook-failed; echo "error: live hook failed for ${green:0:12}; the home stays where it was" >&2; exit 3; }
    status=live
  fi
  [ "$green" = "$tip" ] || status="$status,pinned-behind-${tip:0:12}"
  row trunk-live.tsv "$PN" "$green" "$(date +%s)" "$status"
  echo "live: $PN at ${green:0:12} ($status)"
}

cmd_release() {
  local tip base n vb next default rel body url
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok
  [ ! -e "$STATE/trunk-red-$PN" ] || refuse "$TRUNK is red; fix it before a release"
  tip=$(rev "refs/heads/$TRUNK")
  [ "$(cat "$STATE/trunk-green-$PN")" = "$tip" ] || refuse "$TRUNK tip ${tip:0:12} has not passed the full suite; run verify first"
  base=$(cat "$STATE/trunk-released-$PN"); n=$(git -C "$PROJ" rev-list --count "$base..$tip")
  [ "$n" -gt 0 ] || refuse "nothing to release: $TRUNK has no commits since the last release"
  vb=$(jg_current_version_branch "$PROJ" || true); next=$(( $(printf '%s' "${vb##*-}" | grep -E '^[0-9]+$' || echo 0) + 1 ))
  rel=release/c-$next
  default=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true); default=${default:-main}
  printf 'refs/heads/%s %s refs/heads/%s %s\n' "$TRUNK" "$tip" "$rel" "$base" | (cd "$PROJ" && "$JG_ROOT/core/owner-guard/owner-guard" pre-push) || refuse "owner-guard refused the batch"
  body=$(mktemp); WORK=$body
  { echo "Release batch from the local $TRUNK: $n commits, one per ticket."; echo
    git -C "$PROJ" log --reverse --format='- %h %s' "$base..$tip"; } > "$body"
  git -C "$PROJ" push -q origin "$tip:refs/heads/$rel" || die "push of $rel failed (never forced)"
  url=$(cd "$PROJ" && gh-axi pr create --base "$default" --head "$rel" --title "Release $rel: $n tickets from the local $TRUNK" --body-file "$body") || die "$rel is pushed but the release PR was not opened; run release again"
  put "$STATE/trunk-released-$PN" "$tip"
  row trunk-releases.tsv "$PN" "$rel" "$tip" "$n" "$(date +%s)" "$url"
  echo "released $n commits to $rel: $url"
}

cmd_due() {
  local first
  open_project "${1-}"; tip_ok
  first=$(git -C "$PROJ" log --reverse --format=%ct "$(cat "$STATE/trunk-released-$PN")..refs/heads/$TRUNK" | head -1)
  [ -n "$first" ] && [ $(( $(date +%s) - first )) -ge $(( $(pol release-after-hours) * 3600 )) ]
}

case "${1:-}" in
  init) shift; cmd_init "$@" ;;
  land) shift; cmd_land "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  live) shift; cmd_live "$@" ;;
  release) shift; cmd_release "$@" ;;
  due) shift; cmd_due "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
