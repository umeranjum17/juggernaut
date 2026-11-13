#!/usr/bin/env bash
# The lander's conflict resolution: the owned part of the landing run state `resolving` (core/machines/landing.states, delivering.states).
# Usage: . bin/jg-trunk-resolve-lib.sh
#   jg_trunk_commit_like <project-dir> <tree> <parent> <lane commit>   prints a commit of <tree> on <parent> with the lane commit's author, date and message
#   jg_trunk_resolve <project-dir> <tip> <lane commit> <resolver command> <limit seconds> <scratch dir>
#
# A rebase that meets a conflict is not sent back to the worker. The lander puts the lane's change on the tip in a copy of its own (a
# detached worktree under <scratch dir>, removed again), leaves the conflict in that copy, and runs the resolver command there with a
# time limit. The resolver is an agent the home chose (policy key conflict-resolver); it is told what to resolve in the environment:
#   JG_RESOLVE_CONFLICTS   the conflicted paths, one per line, in a file          JG_RESOLVE_TIP   the commit the change is put on
#   JG_RESOLVE_CANDIDATE   the lane's commit                                       JG_RESOLVE_LIMIT the limit in seconds
# It exits 0 when it resolved the conflict, and non-zero with the reason on its last output line when it cannot.
# On success the resolved commit is printed and the touched files (the conflicted paths and every file the resolver edited beyond
# them) are written, one per line, to <scratch dir>/touched. On failure nothing is printed, the reason is the last line on stderr, and the return
# code is 1. A conflict marker left in a touched file, or a path still unmerged, is a failure: a conflict is never landed dirty.

jg_trunk_commit_like() {  # <project-dir> <tree> <parent> <lane commit>
  local proj=$1 ident=()
  [ -n "$(git -C "$proj" config user.name 2>/dev/null || true)" ] || ident=(-c user.name=jg-trunk -c user.email=jg-trunk@localhost)
  git -C "$proj" log -1 --format=%B "$4" | GIT_AUTHOR_NAME=$(git -C "$proj" log -1 --format=%an "$4") GIT_AUTHOR_EMAIL=$(git -C "$proj" log -1 --format=%ae "$4") \
    GIT_AUTHOR_DATE=$(git -C "$proj" log -1 --format=%aI "$4") git -C "$proj" "${ident[@]+"${ident[@]}"}" commit-tree "$2" -p "$3"
}

jg_trunk_resolve() {  # <project-dir> <tip> <lane commit> <resolver command> <limit seconds> <scratch dir>
  local proj=$1 tip=$2 cand=$3 cmd=$4 limit=$5 scratch=$6 wt conflicts touched rc=0 out tree fresh marks
  mkdir -p "$scratch" || { echo "cannot make the resolver's scratch directory $scratch" >&2; return 1; }
  wt="$scratch/copy"; out="$scratch/resolver.log"; : > "$out"
  git -C "$proj" worktree add -q --detach "$wt" "$tip" >/dev/null 2>&1 || { echo "cannot make the lander's copy at the trunk tip" >&2; return 1; }
  # shellcheck disable=SC2064 # the paths are fixed now
  trap "git -C '$proj' worktree remove --force '$wt' >/dev/null 2>&1 || :; git -C '$proj' worktree prune >/dev/null 2>&1 || :; trap - RETURN" RETURN
  git -C "$wt" -c user.name=jg-trunk -c user.email=jg-trunk@localhost cherry-pick --no-commit "$cand" >/dev/null 2>&1 || :
  conflicts=$(git -C "$wt" diff --name-only --diff-filter=U | sort -u)
  [ -n "$conflicts" ] || { echo "the change puts on the tip without a conflict in the lander's copy; nothing to resolve" >&2; return 1; }
  printf '%s\n' "$conflicts" > "$scratch/conflicts"
  (cd "$wt" && JG_RESOLVE_CONFLICTS="$scratch/conflicts" JG_RESOLVE_TIP=$tip JG_RESOLVE_CANDIDATE=$cand JG_RESOLVE_LIMIT=$limit \
    timeout --kill-after=10 "$limit" bash -c "$cmd" >"$out" 2>&1 </dev/null) || rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then echo "the resolver did not finish inside its limit of $limit seconds" >&2; return 1; fi
  if [ "$rc" -ne 0 ]; then
    echo "the resolver could not resolve it: $(grep . "$out" | tail -n 1 | cut -c1-200 || :)" >&2; return 1
  fi
  touched=$( { printf '%s\n' "$conflicts"; git -C "$wt" diff --name-only; } | grep . | sort -u)
  marks=$(printf '%s\n' "$touched" | while IFS= read -r p; do [ ! -f "$wt/$p" ] || grep -lE '^(<<<<<<<|>>>>>>>)( |$)' "$wt/$p" 2>/dev/null; done)
  [ -z "$marks" ] || { echo "the resolver left a conflict marker in: $(printf '%s' "$marks" | tr '\n' ' ')" >&2; return 1; }
  git -C "$wt" add -A >/dev/null 2>&1
  [ -z "$(git -C "$wt" ls-files -u)" ] || { echo "the resolver left a path unmerged" >&2; return 1; }
  tree=$(git -C "$wt" write-tree) || { echo "the resolved tree cannot be written" >&2; return 1; }
  fresh=$(jg_trunk_commit_like "$proj" "$tree" "$tip" "$cand") || { echo "the resolved commit cannot be made" >&2; return 1; }
  printf '%s\n' "$touched" > "$scratch/touched"
  printf '%s\n' "$fresh"
}
