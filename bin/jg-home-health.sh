#!/usr/bin/env bash
# The health check of one home after a live move, and the pin-back that undoes a bad move on the one home it broke.
# Usage: jg-home-health.sh check <home> [<sha>] [--grace <s>] [--session-max <s>] [--wait <s>]
#        jg-home-health.sh pinback <home> --project <name> --key <home-id> --reason <reason>
#        jg-home-health.sh verify <home> <sha> --project <name> --key <home-id> [check options]
#
# check    Exit 0 and print `ok <home>`, or exit 1 and print the failed fact; the LAST line is `<reason>: <detail>`
#          (bin/jg-update.sh --base reads it into the row). The facts, in order, and the first failure wins:
#            not-at-base          with <sha>: the home's HEAD is not that commit
#            missing-guard        bin/jg-home-guard.sh check says no guard is installed in the home's repository
#            stale-overlay        a launch overlay (state/<id>.git-hooks) lacks a hook of the installer's current set
#                                 (the set is what bin/jg-git-strip-ai-trailers.sh install writes; wrapper text is the
#                                 refresher's business at the locked session start)
#            stale-beacon         the watcher beacon is older than the grace (default jg_poll_derived_grace) or absent;
#                                 --wait <s> keeps looking that long for a restarting watcher to beat once
#            slow-session-start   the home's own bin/jg-supervision-instructions.sh, the read a session start makes
#                                 before it can act, takes longer than --session-max (default 30 s) or fails.
#                                 A real session start is not run: it takes the home's lock, which a live lead holds.
# pinback  Return the home to the HEAD recorded before its last live move and write the row
#          `<project>:<key> <post-move sha> <epoch> rolled-back:<reason> <pre-move HEAD>` in data/trunk-live.tsv.
#          It moves only when ALL hold: a record of the move exists (the home guard's own pre-move record, else a
#          trunk-live.tsv row), the home's HEAD is the recorded post-move commit, the tracked tree is clean, and the
#          pre-move commit still exists. The pre-move HEAD need NOT be on the trunk: the first rollback after the convergence
#          returns to a home-only commit, and the home guard admits that move for JG_TRUNK_PINBACK=1 and to nothing else.
#          It uses `git reset --keep`, so it never discards, stashes or merges, and a refusal leaves the home untouched.
# verify   check at <sha>; on a failure pin the home back, then check it again at the pre-move HEAD.
#            exit 0  healthy, stays on <sha>
#            exit 1  failed on <sha> and pinned back (rolled-back:<reason>), the rollout stops there
#            exit 3  failed on both commits: the row says rolled-back:start-failed-both, ONE `blocked` line goes to the
#                    home's parent channel (bin/jg-parent-channel-lib.sh; Main has no parent, so it is printed), and the
#                    home is left to the existing liveness relaunch (bootstrap's squad_lead sweep, stuck-operator-recovery).
#                    This script never relaunches and never loops: a second `verify` finds the home no longer on <sha>,
#                    the pin-back refuses, and nothing more is written or said.
#          A lead's restart on the old commit is the caller's step between the pin-back and the second check (the second
#          check reads the live watcher beacon; --wait lets a restarting watcher beat once).
# The data directory is JG_DATA_OVERRIDE, else <JG_HOME>/data of the caller (the parent home, not the lead home).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="${JG_DATA_OVERRIDE:-${JG_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}/data}"

die() { echo "jg-home-health: $*" >&2; exit 2; }
short() { printf '%.12s' "$1"; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 2; }
git_home() { local h=$1; shift; env -u GIT_DIR -u GIT_WORK_TREE git -C "$h" "$@"; }

# --- check ---------------------------------------------------------------------------------------------------------

overlay_gap() {  # <home>: prints the first hook the installer's set has and a launch overlay lacks
  local home=$1 ref d h name gap=""
  ref=$(mktemp -d "${TMPDIR:-/tmp}/jg-home-health.XXXXXX") || return 0
  if "$SCRIPT_DIR/jg-git-strip-ai-trailers.sh" install "$ref/hooks" "$home" >/dev/null 2>&1; then
    for d in "$home"/state/*.git-hooks; do
      [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$d/commit-msg" ] || continue
      for h in "$ref"/hooks/*; do
        name=${h##*/}
        [ -x "$d/$name" ] || { gap="$(basename "$d")/$name"; break 2; }
      done
    done
  else
    gap="(the installer's hook set could not be read)"
  fi
  chmod -R u+w "$ref" 2>/dev/null; rm -rf -- "$ref"
  printf '%s' "$gap"
}

cmd_check() {
  local home=${1-} sha="" grace="" session_max=30 wait_s=0 head out age gap start took
  [ -n "$home" ] || usage; shift
  case "${1-}" in ''|--*) ;; *) sha=$1; shift ;; esac
  while [ $# -gt 0 ]; do
    case $1 in
      --grace) grace=${2-}; shift 2 || die "--grace needs seconds" ;;
      --session-max) session_max=${2-}; shift 2 || die "--session-max needs seconds" ;;
      --wait) wait_s=${2-}; shift 2 || die "--wait needs seconds" ;;
      *) die "unknown option $1" ;;
    esac
  done
  [ -d "$home" ] || die "$home is not a directory"
  head=$(git_home "$home" rev-parse HEAD 2>/dev/null) || { echo "not-at-base: $home has no HEAD"; return 1; }
  if [ -n "$sha" ] && [ "$head" != "$(git_home "$home" rev-parse -q --verify "$sha^{commit}" 2>/dev/null || echo "$sha")" ]; then
    echo "not-at-base: HEAD is $(short "$head"), not $(short "$sha")"; return 1
  fi
  if ! out=$("$SCRIPT_DIR/jg-home-guard.sh" check "$home" 2>&1); then echo "missing-guard: $out"; return 1; fi
  gap=$(overlay_gap "$home")
  [ -z "$gap" ] || { echo "stale-overlay: $gap is missing from the launch overlay"; return 1; }
  # shellcheck source=bin/jg-wake-lib.sh
  . "$SCRIPT_DIR/jg-wake-lib.sh"
  [ -n "$grace" ] || grace=$(jg_poll_derived_grace)
  start=$SECONDS
  while :; do
    age=$(jg_watcher_progress_age "$home/state")
    [ "$age" -le "$grace" ] && break
    [ $((SECONDS - start)) -lt "$wait_s" ] || { echo "stale-beacon: the watcher beacon is $age s old (grace $grace s)"; return 1; }
    sleep 1
  done
  [ -f "$home/bin/jg-supervision-instructions.sh" ] || { echo "slow-session-start: the home has no bin/jg-supervision-instructions.sh to read"; return 1; }
  start=$SECONDS
  JG_HOME="$home" JG_ROOT_OVERRIDE="$home" bash "$home/bin/jg-supervision-instructions.sh" >/dev/null 2>&1 \
    || { echo "slow-session-start: the supervision read failed"; return 1; }
  took=$((SECONDS - start))
  [ "$took" -le "$session_max" ] || { echo "slow-session-start: the supervision read took $took s (bound $session_max s)"; return 1; }
  echo "ok $home"
}

# --- pin-back ------------------------------------------------------------------------------------------------------

# Sets REC_PRE and REC_POST from the home guard's own record, else the last live row of trunk-live.tsv for <project>:<key>.
recorded_move() {  # <home> <project> <key>
  local home=$1 common rec
  REC_PRE=""; REC_POST=""
  common=$(git_home "$home" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  if rec=$(cat "$common/jg-home-guard/pre-move" 2>/dev/null) && [ -n "$rec" ]; then
    REC_PRE=${rec%% *}; REC_POST=${rec##* }; return 0
  fi
  [ -r "$DATA/trunk-live.tsv" ] || return 1
  rec=$(awk -F'\t' -v k="$2:$3" '$1 == k && $4 ~ /^live/ && $5 != "" { l = $2 " " $5 } END { print l }' "$DATA/trunk-live.tsv")
  [ -n "$rec" ] || return 1
  REC_POST=${rec%% *}; REC_PRE=${rec##* }
}

cmd_pinback() {
  local home=${1-} project="" key="" reason="" head
  [ -n "$home" ] || usage; shift
  while [ $# -gt 0 ]; do
    case $1 in
      --project) project=${2-}; shift 2 || die "--project needs a name" ;;
      --key) key=${2-}; shift 2 || die "--key needs a home id" ;;
      --reason) reason=${2-}; shift 2 || die "--reason needs text" ;;
      *) die "unknown option $1" ;;
    esac
  done
  [ -n "$project" ] && [ -n "$key" ] && [ -n "$reason" ] || die "pinback needs --project, --key and --reason"
  reason=$(printf '%s' "$reason" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-120)
  recorded_move "$home" "$project" "$key" || { echo "pin-back refused: no record of a live move for $key" >&2; return 1; }
  head=$(git_home "$home" rev-parse HEAD 2>/dev/null) || die "$home has no HEAD"
  [ "$head" = "$REC_POST" ] || { echo "pin-back refused: HEAD $(short "$head") is not the HEAD $(short "$REC_POST") the last live move recorded" >&2; return 1; }
  git_home "$home" cat-file -e "$REC_PRE^{commit}" 2>/dev/null || { echo "pin-back refused: the pre-move HEAD $(short "$REC_PRE") no longer exists" >&2; return 1; }
  [ -z "$(git_home "$home" status --porcelain --untracked-files=no)" ] || { echo "pin-back refused: the home has uncommitted changes" >&2; return 1; }
  JG_TRUNK_PINBACK=1 git_home "$home" reset -q --keep "$REC_PRE" || { echo "pin-back failed: git reset --keep $(short "$REC_PRE") was refused" >&2; return 1; }
  mkdir -p "$DATA"
  printf '%s:%s\t%s\t%s\t%s\t%s\n' "$project" "$key" "$REC_POST" "$(date +%s)" "rolled-back:$reason" "$REC_PRE" >> "$DATA/trunk-live.tsv"
  echo "pinned back $key to $(short "$REC_PRE"): rolled-back:$reason"
}

# --- verify --------------------------------------------------------------------------------------------------------

blocked_line() {  # <home> <text>: ONE line on the parent channel; Main has no parent, so it is printed
  local home=$1 hh_msg=$2 rc
  (
    JG_HOME="${JG_HOME:-$home}"
    # shellcheck source=bin/jg-parent-channel-lib.sh
    . "$SCRIPT_DIR/jg-parent-channel-lib.sh" && jg_parent_channel_report "$home" "$home/state" "$hh_msg"
  ) 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] || echo "no parent channel reached for this home (code $rc): $hh_msg"
}

cmd_verify() {
  local home=${1-} sha=${2-} project="" key="" out reason rest=() second pre
  [ -n "$home" ] && [ -n "$sha" ] || usage; shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --project) project=${2-}; shift 2 || die "--project needs a name" ;;
      --key) key=${2-}; shift 2 || die "--key needs a home id" ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  [ -n "$project" ] && [ -n "$key" ] || die "verify needs --project and --key"
  if out=$(cmd_check "$home" "$sha" "${rest[@]}"); then echo "$out"; return 0; fi
  echo "$out"; reason=${out##*$'\n'}; reason=${reason%%:*}
  recorded_move "$home" "$project" "$key" && pre=$REC_PRE || pre=""
  cmd_pinback "$home" --project "$project" --key "$key" --reason "$reason" || return 1
  if second=$(cmd_check "$home" "$pre" "${rest[@]}"); then return 1; fi
  printf '%s:%s\t%s\t%s\t%s\t%s\n' "$project" "$key" "$sha" "$(date +%s)" "rolled-back:start-failed-both" "$pre" >> "$DATA/trunk-live.tsv"
  echo "rolled-back:start-failed-both: $key fails its health check on $(short "$sha") and on $(short "$pre"): $reason, then ${second##*$'\n'}"
  blocked_line "$home" "blocked: $key did not come up on the new commit $(short "$sha") or the old one $(short "$pre") ($reason); it is pinned back to the old commit and left to the relaunch ladder"
  return 3
}

case "${1-}" in
  check) shift; cmd_check "$@" ;;
  pinback) shift; cmd_pinback "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  *) usage ;;
esac
