#!/usr/bin/env bash
# The local trunk flow: one proved commit per ticket lands on a local trunk branch and is
# live at once, and the accumulated trunk goes out in one batch release.
#
# Usage: jg-trunk.sh init <project-dir> [<base-ref>]   create the trunk (default: the newest release/c-N, else HEAD)
#        jg-trunk.sh land <task-id>                    land the task's one proved commit on the trunk; never goes live
#        jg-trunk.sh verify <project-dir>              run the full suite at the trunk tip: green moves the pin, red stops landings
#        jg-trunk.sh word live|release <project-dir> "<his words>"   record the captain's word for the commit that would go live or out
#        jg-trunk.sh live <project-dir>                move the home to the last fully green commit; refuses without his word
#        jg-trunk.sh ci <project-dir> <sha> green|red  record the CI result for a live commit; red pins the home back to the last green one
#        jg-trunk.sh release <project-dir>             push the trunk and open the ONE release PR trunk -> default branch; refuses without his word
#        jg-trunk.sh rollover <project-dir>            after the release PR merged, cut the next trunk version (trunk-v2, ...) from the default branch
#        jg-trunk.sh retire <project-dir>              clean up an old trunk unforced: only when its release is proved on main and every hotfix is carried; unlanded work is kept and listed
#        jg-trunk.sh due <project-dir>                 exit 0 when the oldest unreleased commit is past release-after-hours
#
# The flow is the same for every project IN local-trunk MODE (data/projects.md `[local-trunk]`); every subcommand
# refuses any other project, whose own delivery rules are unchanged: a lane's one commit lands on the local trunk by itself once its
# sealed done-done proof passed (core/trunk-landing is the registered check that calls `land`), the trunk
# goes live only on the captain's word, and the only pull request is the release one. There is no feature
# pull request and no release branch. Local gates decide landing (done-done receipt, lint, owner-guard, the
# gate chain, the lander's own gate); CI runs after live, and a red CI pins the home back.
#
# The ship branch (state/<id>.meta branch=, default fm/<id>) must hold EXACTLY ONE commit on
# top of the trunk tip, and state/<id>.run-receipt.json must be a PASS for that exact commit. A moved
# tip or a second commit refuses; a moved tip that conflicts names the conflicting paths. The lane
# rebases, fixes and proves again; a conflicting change is never landed dirty.
# `land` runs the same gates as bin/jg-merge-local.sh (bin/jg-merge-gate-lib.sh owns them), plus
# the linked-decision block, then the lander's own gate at the candidate's exact tree in a clean
# clone, then moves the trunk with a compare-and-swap `update-ref`, so a racing lander or a lane
# that moved the ref is refused rather than overwritten. The trunk tip is recorded in
# state/trunk-tip-<project>; a tip that differs from that record was moved by someone other than
# this script (a lane can `git branch -f`), and every subcommand refuses until it is explained.
# Only the lander moves the trunk. A worker never lands. A git reference-transaction hook that every
# subcommand installs in the project refuses any other write to the trunk branch, so `git branch -f trunk`
# or `git update-ref` by hand is stopped where it happens; the record check above stays as the second lock.
#
# The trunk stays SAFE until its release PR lands: nothing forces, rewrites or deletes it (the hook above refuses
# all three, even from this script), and a pin-back moves the home only to a green commit, never the trunk.
# When the release PR has merged, `rollover` (also run by `release`, and by the landing check) cuts the NEXT trunk
# version from the default branch, moves the project onto it and records it (state/trunk-branch-<project>,
# state/trunk-version-<project>, data/trunk-versions.tsv). The old trunk is left exactly as it was.
# Pin-back: state/trunk-green-<project> is the last commit that passed the FULL suite. `live`
# moves the home only to that commit, so a smoke-only landing is not live until `verify` passes.
# A red `verify` or a red `ci` writes state/trunk-red-<project>; while it exists only a commit whose
# message has the line `fixes-red: <red sha>` may land, and `release` refuses. A red `ci` also moves
# the home back to the newest earlier commit that went live and was not red (else the last release).
# The captain's word: `word` writes state/trunk-word-<live|release>-<project>, bound to the one commit
# it names and spent by the command it allows. A worker never records one.
#
# Exit 3 means the home did not move (the live hook failed); a landed commit stays landed.
#
# Every open captain call is a key in bin/jg-trunk-policy-lib.sh with its safe default; nothing
# here changes with the answer. Records: data/trunk-landings.tsv (task, project, commit, epoch,
# gate), data/trunk-live.tsv (project, commit, epoch, status), data/trunk-releases.tsv, data/trunk-ci.tsv, data/trunk-words.tsv.
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

open_project() {  # <project-dir>: sets PROJ PN TRUNK
  local mode
  PROJ=${1:?project directory required}
  git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1 || die "$PROJ is not a git repository"
  PN=$(basename "$PROJ")
  TRUNK=$(jg_trunk_branch "$PN" "$STATE")
  git check-ref-format --branch "$TRUNK" >/dev/null 2>&1 || die "invalid trunk-branch '$TRUNK'"
  # The trunk flow is for local-trunk projects ONLY: a no-mistakes, direct-PR or local-only project keeps its own rules.
  mode=$(JG_HOME="$JG_HOME" JG_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/jg-project-mode.sh" --raw "$PN" 2>/dev/null | cut -d' ' -f1 || true)
  [ "$mode" = local-trunk ] || refuse "$PN is registered ${mode:-as nothing} in data/projects.md, not local-trunk; the trunk flow applies to local-trunk projects only and this project's own delivery rules are unchanged"
  ensure_guard
  [ "$(pol trunk-owner)" = this-home ] || refuse "trunk-owner=$(pol trunk-owner) is not built; only this-home is, and the owner is an open captain call"
}

# The trunk is safe: only this script writes it (JG_TRUNK_WRITER=1 on its own update-ref calls), and even
# this script can only create it or fast-forward it. A rewind, a force or a delete of refs/heads/<trunk> or
# a later trunk version (<trunk>-v2, ...) is refused by the project's reference-transaction hook, so no
# subcommand and no hand can lose a trunk whose release is still open. The one delete it allows is `retire`'s
# (JG_TRUNK_RETIRE=<ref>), which runs only after the old trunk's release merged and its work is carried.
ensure_guard() {
  local hook want base
  base=$(pol trunk-branch)
  hook="$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir)/hooks/reference-transaction"
  # shellcheck disable=SC2016 # the hook body is written out verbatim; its variables expand in the hook
  want=$(printf '#!/bin/sh\n# managed by bin/jg-trunk.sh: only the lander moves the trunk, and only forward\n[ "$1" = prepared ] || exit 0\nwhile read -r old new ref; do\n  case "$ref" in refs/heads/%s|refs/heads/%s-v[0-9]*) ;; *) continue ;; esac\n  case "$new" in *[!0]*) ;; *) [ "${JG_TRUNK_RETIRE:-}" = "$ref" ] && continue; echo "refused: $ref is a trunk and is never deleted" >&2; exit 1 ;; esac\n  [ -n "${JG_TRUNK_WRITER:-}" ] || { echo "refused: $ref moves only through bin/jg-trunk.sh land; nothing writes it by hand" >&2; exit 1; }\n  cur=$(git rev-parse -q --verify "$ref^{commit}" 2>/dev/null || true)\n  [ -z "$cur" ] || git merge-base --is-ancestor "$cur" "$new" || { echo "refused: $ref is never rewound or forced; the trunk only moves forward" >&2; exit 1; }\ndone\nexit 0\n' "$base" "$base")
  if [ -e "$hook" ] && [ "$(cat "$hook")" != "$want" ]; then
    grep -q 'managed by bin/jg-trunk.sh' "$hook" || die "$hook is not the trunk guard; move it aside so the trunk can be protected"
  fi
  mkdir -p "$(dirname "$hook")"; printf '%s\n' "$want" > "$hook"; chmod +x "$hook"
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

# The paths where <candidate> cannot merge cleanly onto <tip>; prints nothing when it merges clean.
conflict_paths() {  # <tip> <candidate>
  local out; out=$(git -C "$PROJ" merge-tree --write-tree --name-only --no-messages "$1" "$2" 2>/dev/null) && return 0
  printf '%s\n' "$out" | sed 1d | paste -sd' ' -
}

# The sealed done-done proof: a PASS receipt for this task's incarnation at the candidate's exact head.
receipt_pass() {  # <id> <meta> <candidate>
  local r="$STATE/$1.run-receipt.json" v h g
  "$SCRIPT_DIR/../core/receipts/bin/jg-receipt-restore.sh" "$STATE" "$1" "$3" >/dev/null 2>&1 || :
  [ -f "$r" ] || refuse "no done-done receipt for $1 at state/$1.run-receipt.json; the lane publishes one for ${3:0:12}"
  command -v jq >/dev/null 2>&1 || refuse "jq is required to read the done-done receipt"
  jq -e . "$r" >/dev/null 2>&1 || refuse "the done-done receipt for $1 is not readable JSON"
  v=$(jq -r '.verdict // ""' "$r"); h=$(jq -r '.head // ""' "$r"); g=$(jq -r '.spawn_gen // ""' "$r")
  [ "$v" = PASS ] || refuse "the done-done receipt for $1 is ${v:-empty}, not PASS"
  [ "$h" = "$3" ] || refuse "the done-done receipt for $1 is for ${h:0:12}, not the lane head ${3:0:12}; prove the final head again"
  [ "$g" = "$(jg_dod_meta_value "$2" spawn_gen)" ] || refuse "the done-done receipt for $1 belongs to another incarnation of the task"
}

# The captain's recorded word: spent by the command it allows, valid for one commit only.
need_word() {  # <live|release> <sha>
  local f="$STATE/trunk-word-$1-$PN"
  [ -f "$f" ] && [ "$(cut -f1 "$f")" = "$2" ] || refuse "no recorded word from the captain to $1 ${2:0:12}; record it with: jg-trunk.sh word $1 $PROJ \"<his words>\""
}
spend_word() { rm -f -- "$STATE/trunk-word-$1-$PN"; }

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
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref -m "trunk: init" "refs/heads/$TRUNK" "$base" ""
  mkdir -p "$STATE"
  put "$STATE/trunk-tip-$PN" "$base"; put "$STATE/trunk-green-$PN" "$base"; put "$STATE/trunk-released-$PN" "$base"
  put "$STATE/trunk-branch-$PN" "$TRUNK"; put "$STATE/trunk-version-$PN" 1; row trunk-versions.tsv "$PN" 1 "$TRUNK" "$base" "$(date +%s)"
  echo "trunk $TRUNK created at ${base:0:12} in $PROJ"
}

cmd_land() {
  local id=${1-} META branch cand tip n red hit rc=0 linked gate cmd
  case " $* " in *" --force"*|*" -f "*|*" --no-verify "*|*" --skip"*) refuse "a landing is never forced: land takes only the task id; rebase the lane on the latest $(pol trunk-branch) tip, fix its conflicts and prove it again" ;; esac
  [ $# -le 1 ] || refuse "land takes only the task id; there is no option that forces or skips a gate"
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
  if ! git -C "$PROJ" merge-base --is-ancestor "$tip" "$cand"; then
    hit=$(conflict_paths "$tip" "$cand")
    [ -z "$hit" ] || refuse "$branch conflicts with $TRUNK (${tip:0:12}) in: $hit; a lane rebases and fixes it, then proves it again; it is never landed dirty"
    refuse "trunk moved: rebase $branch onto $TRUNK (${tip:0:12}) and prove it again"
  fi
  n=$(git -C "$PROJ" rev-list --count "$tip..$cand")
  [ "$n" = 1 ] || refuse "one commit per ticket: $branch has $n commits over $TRUNK; squash it to one"
  receipt_pass "$id" "$META" "$cand"
  git -C "$PROJ" log -1 --format=%B "$cand" | grep -Eq "(^|[^[:alnum:]-])($id|[A-Z]{2,4}-[0-9]+)([^[:alnum:]-]|$)" \
    || refuse "the commit must carry its ticket reference (the task id $id or its ticket key) in its message"
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
  printf 'refs/heads/%s %s refs/heads/%s %s\n' "$TRUNK" "$cand" "$TRUNK" "$tip" | (cd "$PROJ" && "$SCRIPT_DIR/../core/owner-guard/owner-guard" pre-push) || refuse "owner-guard refused $id"
  run_gate "$cand" "$(pol gate-lint)" lint
  gate=$(pol gate-mode)
  case $gate in
    full) cmd=$(pol gate-full) ;;
    smoke) cmd=$(pol gate-smoke); [ -n "$cmd" ] || refuse "gate-mode=smoke but no gate-smoke command is chosen" ;;
    *) refuse "unknown gate-mode '$gate'" ;;
  esac
  run_gate "$cand" "$cmd" "$gate"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref -m "trunk: land $id" "refs/heads/$TRUNK" "$cand" "$tip" || refuse "$TRUNK changed while landing $id"
  put "$STATE/trunk-tip-$PN" "$cand"
  [ "$gate" != full ] || put "$STATE/trunk-green-$PN" "$cand"
  row trunk-landings.tsv "$id" "$PN" "$cand" "$(date +%s)" "$gate"
  # The same merge alert as bin/jg-merge-local.sh: the opt-in fleet ledger's merged event, the ticket close and the post-merge hook.
  [ ! -e "$CONFIG/fleet-ledger" ] || JG_HOME=$JG_HOME JG_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/jg-fleet-ledger.sh" merged "$id" local || true
  JG_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/jg-ticket.sh" "$id" --stage "done" --state "done" || true
  if declare -F jg_merge_post_hook >/dev/null; then jg_merge_post_hook "$CONFIG" "$JG_HOME" "$id" "$META" "$cand" - >&2; fi
  echo "landed $id on $TRUNK (${tip:0:12} -> ${cand:0:12}, gate=$gate) in $PROJ; not live: it goes live only on the captain's word"
}

cmd_verify() {
  local tip rc=0
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok; tip=$(rev "refs/heads/$TRUNK")
  ( run_gate "$tip" "$(pol gate-full)" full ) || rc=$?
  if [ "$rc" -ne 0 ]; then put "$STATE/trunk-red-$PN" "$tip"; echo "trunk is RED at ${tip:0:12}; landings stop except a fixes-red commit" >&2; exit 1; fi
  put "$STATE/trunk-green-$PN" "$tip"; rm -f "$STATE/trunk-red-$PN"
  echo "trunk green at ${tip:0:12}"
}

# Move the home to <sha> through the project's live hook and record it. Exit 3 when the home did not move.
go_live() {  # <sha> <tip>
  local sha=$1 hook status=landed-not-live here there
  hook="$CONFIG/live-hook.$PN"
  if [ ! -x "$hook" ]; then
    here=$(git -C "$JG_ROOT" remote get-url origin 2>/dev/null || echo a); there=$(git -C "$PROJ" remote get-url origin 2>/dev/null || echo b)
    [ "$here" != "$there" ] || hook="$SCRIPT_DIR/jg-trunk-live-home.sh"
  fi
  if [ -x "$hook" ]; then
    "$hook" "$PROJ" "$sha" || { row trunk-live.tsv "$PN" "$sha" "$(date +%s)" hook-failed; echo "error: live hook failed for ${sha:0:12}; the home stays where it was" >&2; exit 3; }
    status=live
  fi
  [ "$sha" = "$2" ] || status="$status,pinned-behind-${2:0:12}"
  row trunk-live.tsv "$PN" "$sha" "$(date +%s)" "$status"
  echo "live: $PN at ${sha:0:12} ($status)"
}

cmd_live() {
  local green tip
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok; tip=$(rev "refs/heads/$TRUNK")
  green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null) || refuse "no fully green trunk commit yet; the home stays where it is"
  need_word live "$green"
  go_live "$green" "$tip"; spend_word live
}

cmd_word() {
  local kind=${1-} sha quote=${3-}
  case $kind in live|release) ;; *) die "usage: jg-trunk.sh word live|release <project-dir> \"<his words>\"" ;; esac
  [ -z "${JG_TASK_ID:-}" ] || refuse "a worker never records the captain's word"
  [ -n "$quote" ] || refuse "the captain's own words are required"
  open_project "${2-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok
  if [ "$kind" = live ]; then sha=$(cat "$STATE/trunk-green-$PN"); else sha=$(rev "refs/heads/$TRUNK"); fi
  put "$STATE/trunk-word-$kind-$PN" "$(printf '%s\t%s\t%s' "$sha" "$(date +%s)" "$quote")"
  row trunk-words.tsv "$PN" "$kind" "$sha" "$(date +%s)" "$quote"
  echo "word recorded: $kind ${sha:0:12} in $PN"
}

# The newest earlier commit that went live and was not red; the last release when none did.
last_green_before() {  # <red sha>
  local c
  while IFS= read -r c; do
    [ "$c" != "$1" ] || continue
    grep -q "^$PN	$c	[0-9]*	red$" "$DATA/trunk-ci.tsv" 2>/dev/null && continue
    git -C "$PROJ" merge-base --is-ancestor "$c" "$1" 2>/dev/null || continue
    echo "$c"; return 0
  done < <(awk -F'\t' -v p="$PN" '$1 == p && $4 ~ /^live/ { print $2 }' "$DATA/trunk-live.tsv" 2>/dev/null | tac)
  cat "$STATE/trunk-released-$PN"
}

cmd_ci() {
  local sha tip back
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok; tip=$(rev "refs/heads/$TRUNK")
  sha=$(rev "${2-}") || die "'${2-}' does not resolve in $PROJ"
  git -C "$PROJ" merge-base --is-ancestor "$sha" "$tip" || refuse "${sha:0:12} is not on $TRUNK"
  case ${3-} in
    green)
      row trunk-ci.tsv "$PN" "$sha" "$(date +%s)" green
      git -C "$PROJ" merge-base --is-ancestor "$(cat "$STATE/trunk-green-$PN")" "$sha" && put "$STATE/trunk-green-$PN" "$sha"
      if [ -e "$STATE/trunk-red-$PN" ] && [ "$sha" != "$(cat "$STATE/trunk-red-$PN")" ] \
        && git -C "$PROJ" merge-base --is-ancestor "$(cat "$STATE/trunk-red-$PN")" "$sha"; then rm -f -- "$STATE/trunk-red-$PN"; fi
      echo "ci green at ${sha:0:12}" ;;
    red)
      row trunk-ci.tsv "$PN" "$sha" "$(date +%s)" red
      back=$(last_green_before "$sha")
      put "$STATE/trunk-red-$PN" "$sha"; put "$STATE/trunk-green-$PN" "$back"
      echo "ci RED at ${sha:0:12}; pinning the home back to ${back:0:12}; landings stop except a fixes-red commit" >&2
      go_live "$back" "$tip" ;;
    *) die "usage: jg-trunk.sh ci <project-dir> <sha> green|red" ;;
  esac
}

# The release PR of the last release, and whether it has merged. The trunk stays untouched until it has.
last_release_url() { awk -F'\t' -v p="$PN" '$1 == p { u = $6 } END { print u }' "$DATA/trunk-releases.tsv" 2>/dev/null || true; }
pr_state() {  # <url>: open|merged|closed|unknown
  local st; st=$( (cd "$PROJ" && gh-axi pr view "$1" 2>/dev/null) | awk '$1 == "state:" { print tolower($2); exit }')
  printf '%s\n' "${st:-unknown}"
}

# Once the release PR has merged, the NEXT trunk version is cut from the default branch and the project moves onto
# it: <trunk>-v2, -v3, ... The old trunk is left exactly as it was. Returns 1, changing nothing, while the PR is not merged.
rollover_if_merged() {
  local url ver new base default
  url=$(last_release_url); [ -n "$url" ] || return 1
  [ "$(cat "$STATE/trunk-rolled-$PN" 2>/dev/null)" != "$url" ] || return 1
  [ "$(pr_state "$url")" = merged ] || return 1
  default=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true); default=${default:-main}
  git -C "$PROJ" fetch -q origin "+refs/heads/$default:refs/remotes/origin/$default" || die "cannot fetch origin/$default to cut the next trunk"
  base=$(rev "refs/remotes/origin/$default") || die "origin/$default is not a commit"
  ver=$(( $(cat "$STATE/trunk-version-$PN" 2>/dev/null || echo 1) + 1 )); new="$(pol trunk-branch)-v$ver"
  rev "refs/heads/$new" >/dev/null && die "$new already exists in $PROJ; the next trunk is never overwritten"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref -m "trunk: version $ver after $url" "refs/heads/$new" "$base" ""
  put "$STATE/trunk-tip-$PN" "$base"; put "$STATE/trunk-green-$PN" "$base"; put "$STATE/trunk-released-$PN" "$base"
  put "$STATE/trunk-branch-$PN" "$new"; put "$STATE/trunk-version-$PN" "$ver"; put "$STATE/trunk-rolled-$PN" "$url"
  rm -f -- "$STATE/trunk-red-$PN"
  row trunk-versions.tsv "$PN" "$ver" "$new" "$base" "$(date +%s)"
  echo "release merged: the project is now on $new (version $ver) cut from $default at ${base:0:12}"
  local old=$TRUNK; TRUNK=$new
  echo "$old is cleaned up only when its work is proved on $default and carried into $new"
  retire_old
}

# Every commit of <old> is in <target>: by ancestry, or by patch when the release was squashed or the fix was cherry-picked.
carried() {  # <old> <target>
  git -C "$PROJ" merge-base --is-ancestor "$1" "$2" 2>/dev/null && return 0
  ! git -C "$PROJ" cherry "$2" "$1" 2>/dev/null | grep -q '^+'
}

# After a release merged and the next trunk was cut, clean the OLD trunk up: delete its remote branch, its local
# branch and any worktree on it. UNFORCED (no --force, no -D, a compare-and-swap ref delete), and only when its
# release is proved on the default branch (the tip it released is in it, by ancestry or by patch) AND every commit
# on it - every hotfix - is carried into the current trunk. A copy holding unlanded work (an uncommitted worktree, the project checkout itself, a tip not carried) is
# kept and listed, never deleted. Idempotent: it prints nothing when no old trunk is left.
retire_old() {
  local cur default main new v b lsha rsha tip wt wb kept blocked sha out
  cur=$(cat "$STATE/trunk-version-$PN" 2>/dev/null || echo 1); [ "$cur" -gt 1 ] || return 0
  default=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true); default=${default:-main}
  git -C "$PROJ" fetch -q origin "+refs/heads/$default:refs/remotes/origin/$default" || { echo "cannot fetch origin/$default; the old trunk is kept"; return 0; }
  main=$(rev "refs/remotes/origin/$default") || return 0; new=$(rev "refs/heads/$TRUNK") || return 0
  while IFS=$'\t' read -r v b; do
    [ -n "$b" ] && [ "$v" -lt "$cur" ] && [ "$b" != "$TRUNK" ] || continue
    lsha=$(rev "refs/heads/$b" || true); rsha=$(git -C "$PROJ" ls-remote --heads origin "refs/heads/$b" 2>/dev/null | cut -f1)
    [ -n "$lsha$rsha" ] || continue
    blocked=; rel=$(awk -F'\t' -v p="$PN" -v b="$b" '$1 == p && $2 == b { t = $3 } END { print t }' "$DATA/trunk-releases.tsv" 2>/dev/null || true)
    if [ -z "$rel" ]; then blocked="no release of $b is recorded"
    elif ! carried "$rel" "$main"; then blocked="its release ${rel:0:12} is not proved on origin/$default"; fi
    for tip in $lsha $rsha; do
      [ -z "$blocked" ] || break
      git -C "$PROJ" cat-file -e "$tip^{commit}" 2>/dev/null || git -C "$PROJ" fetch -q origin "refs/heads/$b" 2>/dev/null </dev/null || true
      git -C "$PROJ" cat-file -e "$tip^{commit}" 2>/dev/null || { blocked="the tip ${tip:0:12} cannot be read"; break; }
      if ! carried "$tip" "$new"; then
        out=$(git -C "$PROJ" cherry "$new" "$tip" | sed -n 's/^+ //p' | while read -r sha; do git -C "$PROJ" log -1 --format='%h %s' "$sha"; done | paste -sd';' -)
        blocked="hotfix not carried into $TRUNK: $out"; break
      fi
    done
    if [ -n "$blocked" ]; then echo "kept $b: $blocked"; continue; fi
    kept=
    while IFS= read -r wt; do
      [ -n "$wt" ] || continue
      if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then echo "kept worktree $wt: it holds uncommitted work on $b"; kept=1
      elif [ "$(realpath "$wt")" = "$(realpath "$PROJ")" ]; then echo "kept $PROJ: the project checkout itself is on $b"; kept=1
      elif git -C "$PROJ" worktree remove "$wt" 2>/dev/null </dev/null; then echo "removed worktree $wt"
      else echo "kept worktree $wt: it could not be removed without force"; kept=1; fi
    done < <(git -C "$PROJ" worktree list --porcelain | awk -v b="refs/heads/$b" '/^worktree /{w=substr($0,10)} $0=="branch " b {print w}')
    if [ -n "$rsha" ]; then
      git -C "$PROJ" push -q origin --delete "$b" 2>/dev/null </dev/null && echo "deleted remote $b" || echo "kept remote $b: the delete was refused"
    fi
    if [ -n "$lsha" ] && [ -z "$kept" ]; then
      JG_TRUNK_RETIRE="refs/heads/$b" git -C "$PROJ" update-ref -d "refs/heads/$b" "$lsha" && echo "deleted local $b" || echo "kept local $b: the delete was refused"
    elif [ -n "$lsha" ]; then echo "kept local $b: a copy of it holds unlanded work"; fi
    [ -n "$kept" ] || row trunk-retired.tsv "$PN" "$b" "$(date +%s)"
  done < <(awk -F'\t' -v p="$PN" '$1 == p { print $2 "\t" $3 }' "$DATA/trunk-versions.tsv" 2>/dev/null)
}

cmd_retire() {
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok
  retire_old
}

cmd_rollover() {
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok
  rollover_if_merged || refuse "no merged release to roll over from; $TRUNK stays as it is until its release PR lands"
}

cmd_release() {
  local tip base n default body url prev
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok
  rollover_if_merged || true
  [ ! -e "$STATE/trunk-red-$PN" ] || refuse "$TRUNK is red; fix it before a release"
  tip=$(rev "refs/heads/$TRUNK")
  [ "$(cat "$STATE/trunk-green-$PN")" = "$tip" ] || refuse "$TRUNK tip ${tip:0:12} has not passed the full suite; run verify first"
  base=$(cat "$STATE/trunk-released-$PN"); n=$(git -C "$PROJ" rev-list --count "$base..$tip")
  [ "$n" -gt 0 ] || refuse "nothing to release: $TRUNK has no commits since the last release"
  need_word release "$tip"
  default=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true); default=${default:-main}
  printf 'refs/heads/%s %s refs/heads/%s %s\n' "$TRUNK" "$tip" "$TRUNK" "$base" | (cd "$PROJ" && "$SCRIPT_DIR/../core/owner-guard/owner-guard" pre-push) || refuse "owner-guard refused the batch"
  git -C "$PROJ" push -q origin "$tip:refs/heads/$TRUNK" || die "push of $TRUNK failed (never forced)"
  # The release PR is the trunk itself going into the default branch: no release branch, one PR.
  # While the last release PR is still open, the push above already carried the new commits into it.
  prev=$(last_release_url)
  if [ -n "$prev" ] && [ "$(pr_state "$prev")" = open ]; then
    url=$prev
  else
    body=$(mktemp); WORK=$body
    { echo "Release batch from the local $TRUNK: $n commits, one per ticket."; echo
      git -C "$PROJ" log --reverse --format='- %h %s' "$base..$tip"; } > "$body"
    url=$(cd "$PROJ" && gh-axi pr create --base "$default" --head "$TRUNK" --title "Release: $n tickets from the local $TRUNK" --body-file "$body") || die "$TRUNK is pushed but the release PR was not opened; run release again"
  fi
  put "$STATE/trunk-released-$PN" "$tip"; spend_word release
  row trunk-releases.tsv "$PN" "$TRUNK" "$tip" "$n" "$(date +%s)" "$url"
  echo "released $n commits from $TRUNK: $url"
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
  word) shift; cmd_word "$@" ;;
  live) shift; cmd_live "$@" ;;
  ci) shift; cmd_ci "$@" ;;
  rollover) shift; cmd_rollover "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  release) shift; cmd_release "$@" ;;
  due) shift; cmd_due "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
