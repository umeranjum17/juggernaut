#!/usr/bin/env bash
# The home guard: no commit reaches a home's `main` or detached HEAD except from the local trunk.
# Usage: jg-home-guard.sh install <home> [--tip <sha>] [--pre <sha>]   write the guard into the home's repository and record the trunk tip
#        jg-home-guard.sh check <home>                                  exit 0 and say `present`, or exit 1 and say `missing: <why>`
#        jg-home-guard.sh uninstall <home>                              remove the guard (the rollback; this installer is its only writer)
#        reference-transaction hook mode (git runs the installed copy as `reference-transaction <state>`)
#
# `install` copies this very script to <git-common-dir>/hooks/reference-transaction, so the guard has no path to a
# bin/ that a later update replaces and a missing helper can never lock a home. It records the trunk tip in
# <git-dir>/jg-home-guard/trunk-tip (--tip, else JG_TRUNK_TIP, else the home's HEAD, which is the trunk commit the
# live move just made). bin/jg-update.sh --base calls `install` after it moves a home and `check` in the health step.
# A home that is also a local-trunk project already holds the trunk guard of bin/jg-trunk.sh in that hook file: `install`
# keeps it as <git-common-dir>/hooks/reference-transaction.chained, the hook runs it first with the same input (its refusal
# is the refusal), bin/jg-trunk.sh writes its guard there while the home guard holds the hook file, and `uninstall` puts it
# back. Any other hook already there is refused untouched. A rerun leaves both files byte-identical.
#
# What the hook guards (state `prepared`): the ref refs/heads/main in the home's repository, and HEAD when the move is a
# detached one in the home's own checkout (a lane worktree, a linked pool worktree and a branch other than main are not the
# home's business). A move of a guarded ref passes when its new commit is
#   - the trunk tip or an ancestor of it (a fast-forward or a rewind along the trunk), or
#   - a release: a merge commit whose parents are all on the trunk (origin/main after the release PR merged), or
#   - admitted by a writer flag the live path sets, below.
# Anything else is refused with exit 1 and the reason, and the ref stays where it was. A delete of main is refused.
# Writer flags (the only ones; there is no bypass variable, the rollback is removing the hook):
#   JG_TRUNK_LIVE=1     the live move (bin/jg-update.sh --base): admits a fast-forward to a newer trunk tip and the contained
#                       re-point of a diverged home, which is a `reset --keep` to a commit that already holds the home's whole
#                       tree (a three-way merge of the home's HEAD into it gives back exactly that commit). With JG_TRUNK_TIP=<sha>
#                       the target must also be on that tip. A committed live move records its tip and the HEAD it left.
#   JG_TRUNK_PINBACK=1  the rollback of a failed health check: admits a move to the HEAD recorded before the last live move
#                       (the guard's own record, or a data/trunk-live.tsv row <home> <post-move sha> <epoch> <status> <pre-move sha>
#                       under JG_DATA_OVERRIDE) and to nothing else.
# With no trunk tip recorded the guard is inactive. A recorded tip whose commit is missing from the repository is warned
# about and does not block: a guard that cannot decide steps aside rather than lock the home.
# Known limits: the hook runs only where git reaches the repository's own hooks directory (a launch overlay that drops
# reference-transaction bypasses it), and a checkout of a lane branch in the home's own checkout is not judged because git
# reports it exactly like `git worktree add`.
set -u
MARK='managed by bin/jg-home-guard.sh'
CHAINED=reference-transaction.chained
SELF="${BASH_SOURCE[0]}"

die() { echo "jg-home-guard: $*" >&2; exit 1; }
is_zero() { case $1 in '' | *[!0]*) return 1 ;; *) return 0 ;; esac; }
short() { printf '%.12s' "$1"; }
commit_of() { git rev-parse -q --verify "$1^{commit}" 2>/dev/null; }
on_trunk() { git merge-base --is-ancestor "$1" "$2" 2>/dev/null; }

# --- hook mode ---------------------------------------------------------------------------------------------------

pinback_ok() {  # <old> <new>
  local old=$1 new=$2 data
  [ -n "$old" ] || return 1
  [ "$(cat "$DIR/pre-move" 2>/dev/null)" = "$new $old" ] && return 0
  data="${JG_DATA_OVERRIDE:-${JG_HOME:-$(cd -P "$COMMON/.." && pwd -P)}/data}/trunk-live.tsv"
  [ -r "$data" ] && awk -F'\t' -v o="$old" -v n="$new" '$2 == o && $5 == n { f = 1 } END { exit !f }' "$data"
}

live_ok() {  # <old> <new>: sets WHY
  local old=$1 new=$2 tree
  if [ -n "${JG_TRUNK_TIP:-}" ] && ! on_trunk "$new" "$JG_TRUNK_TIP"; then WHY="$(short "$new") is not on the trunk tip $(short "$JG_TRUNK_TIP") the live move named"; return 1; fi
  [ -n "$old" ] || return 0
  on_trunk "$old" "$new" && return 0
  tree=$(git merge-tree --write-tree "$old" "$new" 2>/dev/null | head -n 1) || tree=
  [ -n "$tree" ] && [ "$tree" = "$(git rev-parse "$new^{tree}")" ] && return 0
  WHY="the live move to $(short "$new") would drop content of the home's HEAD $(short "$old") that the trunk does not hold"; return 1
}

trunk_ok() {  # <new>: sets WHY
  local new=$1 parents p
  [ -n "$TIP" ] || return 0
  commit_of "$TIP" >/dev/null || { echo "jg-home-guard: the recorded trunk tip $(short "$TIP") is not in this repository; not judging" >&2; return 0; }
  on_trunk "$new" "$TIP" && return 0
  parents=$(git rev-list --parents -n 1 "$new" 2>/dev/null)
  # shellcheck disable=SC2086 # the parents are plain object names
  set -- $parents; shift
  if [ "$#" -ge 2 ]; then
    for p; do on_trunk "$p" "$TIP" || { WHY="$(short "$new") is not on the trunk (trunk tip $(short "$TIP")): a merge with $(short "$p") from outside it"; return 1; }; done
    return 0
  fi
  WHY="$(short "$new") is not on the trunk (trunk tip $(short "$TIP")), and is not a release merge of trunk commits"; return 1
}

judge() {  # <ref> <old> <new>: prints the reason and returns 1 to refuse
  local ref=$1 old=$2 new=$3 flagwhy=""
  WHY=""
  if is_zero "$new"; then
    [ "$ref" != refs/heads/main ] || { echo "refs/heads/main is never deleted in a home"; return 1; }
    return 0
  fi
  case $new in ref:refs/heads/main) new=$(commit_of refs/heads/main) || return 0 ;; ref:*) return 0 ;; esac
  if is_zero "$old"; then if [ "$ref" = HEAD ]; then old=$(commit_of HEAD) || old=; else old=; fi; fi
  [ "$old" != "$new" ] || return 0
  if [ "${JG_TRUNK_PINBACK:-}" = 1 ]; then
    pinback_ok "$old" "$new" && return 0
    flagwhy="a pin-back goes only to the HEAD recorded before the last live move (pre-move), and $(short "$new") is not it"
  fi
  if [ "${JG_TRUNK_LIVE:-}" = 1 ]; then live_ok "$old" "$new" && return 0; flagwhy=$WHY; fi
  trunk_ok "$new" && return 0
  echo "${flagwhy:-$WHY}"; return 1
}

record_live() {  # <old> <new>: a committed live move records the HEAD it left and the tip it reached
  local old=$1 new=$2 tip=${JG_TRUNK_TIP:-}
  is_zero "$old" || [ -z "$old" ] && return 0
  [ -n "$tip" ] || tip=$new
  mkdir -p "$DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$old" "$new" > "$DIR/pre-move"
  if [ -z "$TIP" ] || ! on_trunk "$new" "$TIP"; then printf '%s\n' "$tip" > "$DIR/trunk-tip"; fi
}

hook() {
  local state=$1 old new ref why input gitdir
  COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
  # The trunk guard this hook took the place of judges the same transaction first; its refusal is the refusal.
  input=$(cat; printf x); input=${input%x}
  # (a chained hook that does not read its input closes the pipe early, which is not an error)
  if [ -x "$COMMON/hooks/$CHAINED" ]; then printf '%s' "$input" 2>/dev/null | "$COMMON/hooks/$CHAINED" "$@" || exit $?; fi
  gitdir=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null) || exit 0
  DIR="$gitdir/jg-home-guard"; TIP=$(cat "$DIR/trunk-tip" 2>/dev/null || true)
  [ -f "$DIR/trunk-tip" ] || exit 0
  case $state in
    prepared) ;;
    committed) [ "${JG_TRUNK_LIVE:-}" = 1 ] || exit 0 ;;
    *) exit 0 ;;
  esac
  while read -r old new ref; do
    case $ref in
      refs/heads/main) ;;
      HEAD) case $new in ref:*) continue ;; esac ;;
      *) continue ;;
    esac
    if [ "$state" = committed ]; then case $new in ref:*) ;; *) record_live "$old" "$new" ;; esac; continue; fi
    if ! why=$(judge "$ref" "$old" "$new"); then
      echo "refused: $ref does not move to $(short "$new"): $why; a home's main moves only along the local trunk (bin/jg-trunk.sh live) [transaction: $(short "$old") -> $(short "$new")]" >&2
      exit 1
    fi
  done < <(printf '%s' "$input")
  exit 0
}

# --- installer ---------------------------------------------------------------------------------------------------

gitdir_of() { git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null || die "$1 is not a git repository"; }
common_of() { git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || die "$1 is not a git repository"; }

cmd_install() {
  local home=${1-} tip="${JG_TRUNK_TIP:-}" pre="" common hook dir tmp
  [ -n "$home" ] || die "usage: jg-home-guard.sh install <home> [--tip <sha>] [--pre <sha>]"; shift
  while [ $# -gt 0 ]; do
    case $1 in --tip) tip=${2-}; shift 2 || die "--tip needs a commit" ;; --pre) pre=${2-}; shift 2 || die "--pre needs a commit" ;; *) die "unknown option $1" ;; esac
  done
  common=$(common_of "$home"); hook="$common/hooks/reference-transaction"; dir="$(gitdir_of "$home")/jg-home-guard"
  [ -n "$tip" ] || tip=$(git -C "$home" rev-parse HEAD 2>/dev/null) || die "$home has no HEAD to record as the trunk tip"
  tip=$(git -C "$home" rev-parse -q --verify "$tip^{commit}") || die "trunk tip $tip is not a commit in $home"
  mkdir -p "$common/hooks" "$dir"
  if [ -e "$hook" ] && ! grep -q "$MARK" "$hook"; then
    # The trunk guard (bin/jg-trunk.sh) of a home that is also a local-trunk project keeps working: it moves to the
    # chained slot this hook runs first, and bin/jg-trunk.sh writes it there from then on. Any other hook stays where it is.
    grep -q '^# managed by bin/jg-trunk.sh:' "$hook" || die "$hook is not the home guard; move it aside so the home can be guarded"
    if [ -e "$common/hooks/$CHAINED" ] && ! grep -q '^# managed by bin/jg-trunk.sh:' "$common/hooks/$CHAINED"; then
      die "$common/hooks/$CHAINED is not the trunk guard; move it aside so the home can be guarded"
    fi
    tmp=$(mktemp "$common/hooks/.rt.XXXXXX") || die "cannot write into $common/hooks"
    if ! cp -p -- "$hook" "$tmp" || ! mv -f -- "$tmp" "$common/hooks/$CHAINED"; then rm -f -- "$tmp"; die "cannot keep the trunk guard at $common/hooks/$CHAINED"; fi
  fi
  tmp=$(mktemp "$common/hooks/.rt.XXXXXX") || die "cannot write into $common/hooks"
  sed "2i # $MARK: a home's main and detached HEAD move only along the local trunk" "$SELF" > "$tmp" || die "cannot write $hook"
  chmod 755 "$tmp" || die "cannot write $hook"
  mv -f -- "$tmp" "$hook" || die "cannot write $hook"
  printf '%s\n' "$tip" > "$dir/trunk-tip.new" && mv -f -- "$dir/trunk-tip.new" "$dir/trunk-tip"
  if [ -n "$pre" ]; then pre=$(git -C "$home" rev-parse -q --verify "$pre^{commit}") || die "pre-move $pre is not a commit in $home"; printf '%s %s\n' "$pre" "$(git -C "$home" rev-parse HEAD)" > "$dir/pre-move"; fi
  echo "home guard installed in $home (trunk tip $(short "$tip"))$([ ! -x "$common/hooks/$CHAINED" ] || printf '; it runs the trunk guard first')"
}

cmd_check() {
  local home=${1-} common hook tip
  [ -n "$home" ] || die "usage: jg-home-guard.sh check <home>"
  common=$(common_of "$home"); hook="$common/hooks/reference-transaction"
  if [ ! -x "$hook" ] || ! grep -q "$MARK" "$hook" 2>/dev/null; then echo "missing: no home guard hook in $common/hooks"; exit 1; fi
  tip=$(cat "$(gitdir_of "$home")/jg-home-guard/trunk-tip" 2>/dev/null) && [ -n "$tip" ] || { echo "missing: the home guard has no recorded trunk tip"; exit 1; }
  echo "present (trunk tip $(short "$tip"))"
}

cmd_uninstall() {
  local home=${1-} common hook dir other
  [ -n "$home" ] || die "usage: jg-home-guard.sh uninstall <home>"
  common=$(common_of "$home"); hook="$common/hooks/reference-transaction"
  dir="$(gitdir_of "$home")/jg-home-guard"
  if [ -e "$hook" ]; then grep -q "$MARK" "$hook" || die "$hook is not the home guard; leaving it"; fi
  rm -f -- "$dir/trunk-tip" "$dir/pre-move"; rmdir "$dir" 2>/dev/null || true
  for other in "$common/jg-home-guard/trunk-tip" "$common"/worktrees/*/jg-home-guard/trunk-tip; do
    [ ! -f "$other" ] || { echo "home guard removed from $home"; return; }
  done
  if [ -e "$hook" ]; then grep -q "$MARK" "$hook" || die "$hook is not the home guard; leaving it"; rm -f -- "$hook"; fi
  # A trunk guard the hook ran first goes back to being the repository's hook.
  if [ -e "$common/hooks/$CHAINED" ]; then mv -f -- "$common/hooks/$CHAINED" "$hook" || die "cannot put the trunk guard back at $hook"; fi
  echo "home guard removed from $home"
}

case "${1:-}" in
  preparing | prepared | committed | aborted) hook "$@" ;;
  install) shift; cmd_install "$@" ;;
  check) shift; cmd_check "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  *) sed -n '2,/^set -u$/p' "$SELF" | sed -e 's/^# \{0,1\}//' -e '$d' >&2; exit 2 ;;
esac
